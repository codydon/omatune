import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One instance for the whole shell (manifest kind "service", keepLoaded), so
// every bar on every monitor sees the same queue and there is one connection
// to mpv. BarWidget and Panel reach it with bar.shell.serviceFor("codydon.omatune").
//
// Playback state is not stored here: mpv owns the playlist and this service
// mirrors it through observe_property on mpv's JSON IPC socket. mpv is a
// child Process owned by this service, so it stops with the plugin or the
// shell. Network work runs in short-lived backend Processes.
Item {
  id: root

  property var shell: null

  readonly property string backendPath: decodeURIComponent(String(Qt.resolvedUrl("ytm-backend")).replace(/^file:\/\//, ""))
  readonly property string storePath: decodeURIComponent(String(Qt.resolvedUrl("ytm-store")).replace(/^file:\/\//, ""))
  readonly property string localScanPath: decodeURIComponent(String(Qt.resolvedUrl("local-music-scan")).replace(/^file:\/\//, ""))
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string socketPath: runtimeDir !== "" ? runtimeDir + "/codydon-omatune/mpv.sock" : ""

  // Children get a minimal, fixed environment rather than the shell's:
  // a fixed PATH, and only what mpv needs for audio (XDG_RUNTIME_DIR),
  // MPRIS (the session bus) and yt-dlp's cache (HOME).
  // XDG_STATE_HOME / XDG_CACHE_HOME are passed only when set, so the
  // storage helper uses the same folders as the rest of the desktop.
  readonly property var childEnvironment: {
    var env = {
      "HOME": Quickshell.env("HOME") || "",
      "XDG_RUNTIME_DIR": runtimeDir,
      "DBUS_SESSION_BUS_ADDRESS": Quickshell.env("DBUS_SESSION_BUS_ADDRESS") || "",
      "PATH": "/usr/bin",
      "LANG": "C.UTF-8"
    }
    var state = Quickshell.env("XDG_STATE_HOME") || ""
    var cache = Quickshell.env("XDG_CACHE_HOME") || ""
    if (state.charAt(0) === "/") env["XDG_STATE_HOME"] = state
    if (cache.charAt(0) === "/") env["XDG_CACHE_HOME"] = cache
    return env
  }
  readonly property int maxReplyBytes: 262144

  // ---- Search
  property string query: ""
  property var results: []
  property bool searching: false
  property string searchError: ""
  property int searchToken: 0

  // ---- Search suggestions (best effort: failures clear, never error)
  property var suggestions: []
  property int suggestToken: 0

  // ---- Playback, mirrored from mpv
  property var playlist: []
  property int playlistPos: -1
  property bool paused: false
  // mpv keeps two independent mutes (`mute` and `ao-mute`): media keys and
  // MPRIS can set either one, so both are mirrored and either one counts.
  property bool muteProp: false
  property bool aoMuteProp: false
  readonly property bool muted: muteProp || aoMuteProp
  property bool idle: true
  property bool buffering: false
  property real position: 0
  property real duration: 0
  property string mediaTitle: ""
  property var meta: Object.create(null)

  // ---- Saved queue, shown until the player starts. Nothing plays until
  //      the user presses play or picks a song.
  property var restored: ({ tracks: [], index: 0, position: 0 })
  readonly property bool restoring: restored.tracks.length > 0 && !sockConnected && !starting && playlist.length === 0
  readonly property var resumeTrack: restoring ? restored.tracks[restored.index] : null

  readonly property var queue: restoring ? restoredRows(restored) : Model.buildQueue(playlist, meta, cacheDir)
  readonly property var current: !restoring && playlistPos >= 0 && playlistPos < queue.length ? queue[playlistPos] : null
  readonly property bool hasTrack: current !== null && !idle
  readonly property bool playing: hasTrack && !paused
  readonly property string nowTitle: current ? current.title : Model.plain(mediaTitle, 200)
  readonly property string nowArtist: current ? current.artist : ""

  // ---- Lifecycle
  property bool starting: false
  property bool radioLoading: false
  property int radioToken: 0
  property string lastError: ""
  property var pending: []
  property int connectAttempts: 0

  // ---- Search history
  property var history: []

  // ---- Local library, scanned recursively from ~/Music
  property var localTracks: []
  property bool localScanning: false
  property string localError: ""

  // ---- Offline cache
  property var cachedTracks: []
  property string cacheDir: ""
  property real cacheBytes: -1
  readonly property var cached: Model.cacheMap(cachedTracks)
  property var cacheQueue: []
  property bool caching: false
  property string cacheError: ""

  // Settings the bar widget pushes in.
  property bool autoRadio: true
  property bool saveHistory: true
  property bool cacheSongs: true
  property int cacheLimitMB: 1024

  function restoredRows(r) {
    var rows = []
    for (var i = 0; i < r.tracks.length; i++) {
      var t = r.tracks[i]
      rows.push({ index: i, id: t.id, title: t.title, artist: t.artist, album: t.album, duration: t.duration, current: i === r.index })
    }
    return rows
  }

  function sourceOf(track) {
    return Model.sourceFor(track, cached, cacheDir)
  }

  function scanLocalMusic() {
    if (localScanning) return
    localScanning = true
    localError = ""
    startRun(["/usr/bin/timeout", "-k", "2", "--", "20", "/usr/bin/python3", "-I", "-S", localScanPath],
      Model.parseLocalLibrary, 20, function(reply) {
        root.localScanning = false
        if (!reply.ok) { root.localError = reply.error; return }
        root.localTracks = reply.tracks
      }, 8388608)
  }

  function playLocal(track) {
    var command = Model.localFileCommand(track, "replace")
    if (!command) return
    lastError = ""
    restored = { tracks: [], index: 0, position: 0 }
    radioToken++
    radioLoading = false
    send(command)
    send(["set_property", "pause", false])
  }

  function enqueueLocal(track) {
    var command = Model.localFileCommand(track, "append")
    if (command) send(command)
  }

  // ---------------------------------------------------------------- search

  function search(text) {
    // Same bounds for the panel and for IPC callers.
    var q = String(text || "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 200)
    if (q === "") { results = []; searchError = ""; return }
    query = q
    searching = true
    searchError = ""
    var token = ++searchToken
    runBackend(["search", q], function(reply) {
      if (token !== root.searchToken) return
      root.searching = false
      if (!reply.ok) { root.searchError = reply.error; root.results = []; return }
      root.meta = Model.rememberTracks(root.meta, reply.tracks)
      root.results = reply.tracks
      if (reply.tracks.length === 0) root.searchError = "No songs matched “" + Model.plain(q, 60) + "”. Try fewer words."
      else root.rememberSearch(q)
    })
    suggestions = []
  }

  // Autocomplete for the search box. Same bounds as search, but failures
  // stay silent: a missing dropdown must never break typing. Short input
  // never reaches the network.
  function fetchSuggestions(text) {
    var q = String(text || "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 200)
    if (q.length < 2) { suggestions = []; return }
    var token = ++suggestToken
    runBackend(["suggest", q], function(reply) {
      if (token !== root.suggestToken) return
      root.suggestions = reply.ok ? reply.suggestions : []
    }, Model.parseSuggestions)
  }

  // ---------------------------------------------------------------- history

  function rememberSearch(q) {
    if (!saveHistory) return
    history = Model.pushHistory(history, q)
    runStore(["history-add", q], Model.parseHistory, 10, function(reply) {
      if (reply.ok) root.history = reply.history
    })
  }

  function forgetSearch(q) {
    var text = String(q || "").slice(0, 200)
    history = history.filter(function(h) { return h.toLowerCase() !== text.toLowerCase() })
    runStore(["history-remove", text], Model.parseHistory, 10, function(reply) {
      if (reply.ok) root.history = reply.history
    })
  }

  function clearHistory() {
    history = []
    runStore(["history-clear"], Model.parseHistory, 10, function() {})
  }

  function clearSearch() {
    searchToken++
    searching = false
    results = []
    searchError = ""
    query = ""
  }

  // ---------------------------------------------------------------- queue

  // ArchiveTune behaviour: picking a song plays it now and, unless turned
  // off, fills the queue with that song's radio so music keeps going.
  function playNow(track, withRadio) {
    if (!track || !Model.isVideoId(track.id)) return
    lastError = ""
    restored = { tracks: [], index: 0, position: 0 }
    meta = Model.rememberTracks(meta, [track])
    var token = ++radioToken
    send(Model.loadfileCommand(track, "replace", sourceOf(track)))
    send(["set_property", "pause", false])
    if (withRadio === undefined ? autoRadio : withRadio) fillRadio(track, token)
    else radioLoading = false
  }

  function enqueue(track) {
    if (!track || !Model.isVideoId(track.id)) return
    meta = Model.rememberTracks(meta, [track])
    if (restoring) {
      if (restored.tracks.length >= 200) return
      restored = { tracks: restored.tracks.concat([track]), index: restored.index, position: restored.position }
      saveRestored()
      return
    }
    send(Model.loadfileCommand(track, "append", sourceOf(track)))
  }

  // Plays an offline song and queues the other offline songs after it.
  // No radio: that needs a connection, and this list is for when there
  // might not be one.
  function playCached(index) {
    var list = cachedTracks
    if (index < 0 || index >= list.length) return
    lastError = ""
    restored = { tracks: [], index: 0, position: 0 }
    radioToken++
    radioLoading = false
    meta = Model.rememberTracks(meta, list)
    send(Model.loadfileCommand(list[index], "replace", sourceOf(list[index])))
    send(["set_property", "pause", false])
    for (var i = index + 1; i < list.length && i < index + 200; i++)
      send(Model.loadfileCommand(list[i], "append", sourceOf(list[i])))
  }

  // Loads the saved queue into mpv and starts playing `index`, resuming
  // part-way in when it's the song that was playing before.
  function resume(index) {
    var r = restored
    if (r.tracks.length === 0) return
    var at = Model.clampIndex(index, r.tracks.length)
    lastError = ""
    meta = Model.rememberTracks(meta, r.tracks)
    restored = { tracks: [], index: 0, position: 0 }
    send(["playlist-clear"])
    for (var i = 0; i < r.tracks.length; i++)
      send(Model.loadfileCommand(r.tracks[i], "append-idle", sourceOf(r.tracks[i]), i === at && at === r.index ? r.position : 0))
    send(["playlist-play-index", at])
    send(["set_property", "pause", false])
  }

  function saveRestored() {
    runStore(["queue-put", Model.queueSnapshot(restored.tracks, restored.index, restored.position)], parseAny, 10, function() {})
  }

  // Appends the seed's "up next" mix. The token drops a reply that arrives
  // after the user has already picked something else.
  function fillRadio(track, token) {
    radioLoading = true
    runBackend(["radio", track.id], function(reply) {
      if (token !== root.radioToken) return
      root.radioLoading = false
      if (!reply.ok) { root.lastError = reply.error; return }
      root.meta = Model.rememberTracks(root.meta, reply.tracks)
      // The seed was just loaded with "replace"; mpv may not have reported
      // the new playlist yet, so dedupe against the seed explicitly too.
      var additions = Model.radioAdditions(reply.tracks, root.queue.concat([{ id: track.id }]))
      for (var i = 0; i < additions.length; i++) root.send(Model.loadfileCommand(additions[i], "append", root.sourceOf(additions[i])))
    })
  }

  function playIndex(index) {
    if (index < 0 || index >= queue.length) return
    if (restoring) { resume(index); return }
    send(["playlist-play-index", index])
    send(["set_property", "pause", false])
  }

  function removeIndex(index) {
    if (index < 0 || index >= queue.length) return
    if (restoring) {
      var tracks = restored.tracks.slice()
      tracks.splice(index, 1)
      var at = restored.index > index ? restored.index - 1 : Math.min(restored.index, tracks.length - 1)
      restored = { tracks: tracks, index: Math.max(0, at), position: index === restored.index ? 0 : restored.position }
      saveRestored()
      return
    }
    send(["playlist-remove", index])
  }

  function clearQueue() {
    send(["playlist-clear"])
  }

  // ---------------------------------------------------------------- transport

  function togglePause() {
    if (restoring) resume(restored.index)
    else if (hasTrack) send(["cycle", "pause"])
  }
  // mpv's mirrored mutes can lag (ao-mute only exists once there is an audio
  // output), so ask it which way it is before flipping, instead of trusting
  // the mirror and inverting the wrong way round.
  property bool muteTogglePending: false

  function toggleMute() {
    if (!sockConnected || muteTogglePending) return
    muteTogglePending = true
    writeCommand(["get_property", "ao-mute"], 9003)
  }

  function applyMute(value) {
    send(["set_property", "mute", value])
    send(["set_property", "ao-mute", value])
  }

  function next() { send(["playlist-next", "weak"]) }
  function previous() {
    // Like every music app: back restarts the song unless it just began.
    if (position > 3) send(["seek", 0, "absolute"])
    else send(["playlist-prev", "weak"])
  }
  function seek(seconds) {
    var s = Number(seconds)
    if (!isFinite(s) || s < 0) return
    send(["seek", Math.min(s, Math.max(0, duration)), "absolute"])
  }

  // Asks mpv to quit, then escalates: TERM after 2 s, KILL after 4 s.
  function stop() {
    // Keep the queue so it can be resumed later.
    if (sockConnected && playlist.length > 0) saveQueueNow()
    pending = []
    radioToken++
    radioLoading = false
    connectRetry.stop()
    starting = false
    if (playerProc.running) {
      stopping = true
      writeCommand(["quit"])
      playerKill.stage = 0
      playerKill.restart()
    }
    dropSocket()
    resetPlayback()
  }

  // ---------------------------------------------------------------- mpv IPC

  // A Socket that failed once does not reconnect reliably when `connected`
  // is toggled, so every attempt gets a fresh Socket object and a stale one
  // can never deliver lines or state changes.
  property var sock: null
  property bool sockConnected: false
  readonly property bool connected: sockConnected

  function writeCommand(command, requestId) {
    if (!sock || !sockConnected) return false
    var msg = { command: command }
    if (requestId !== undefined) msg.request_id = requestId
    sock.write(JSON.stringify(msg) + "\n")
    sock.flush()
    return true
  }

  function send(command) {
    if (writeCommand(command)) return
    if (pending.length < 260) pending = pending.concat([command])
    ensureStarted()
  }

  function ensureStarted() {
    if (starting || sockConnected) return
    starting = true
    stopping = false
    lastError = ""
    connectAttempts = 0
    if (!playerProc.running) playerProc.running = true
    connectRetry.restart()
  }

  function connectSocket() {
    if (socketPath === "") return
    dropSocket()
    var s = socketComponent.createObject(root, { path: socketPath })
    if (!s) return
    sock = s
    s.connected = true
  }

  function dropSocket() {
    var old = sock
    sock = null
    sockConnected = false
    muteTogglePending = false
    if (old) {
      old.connected = false
      old.destroy()
    }
  }

  function socketLost(s) {
    if (s !== sock) return
    var wasConnected = sockConnected
    dropSocket()
    // While starting, the retry timer keeps trying; otherwise mpv is gone.
    if (wasConnected && !starting) resetPlayback()
  }

  function onMpvConnected() {
    starting = false
    connectRetry.stop()
    var observed = ["pause", "mute", "ao-mute", "playlist", "playlist-pos", "duration", "media-title", "idle-active", "paused-for-cache"]
    for (var i = 0; i < observed.length; i++) writeCommand(["observe_property", i + 1, observed[i]])
    var queued = pending
    pending = []
    for (var j = 0; j < queued.length; j++) writeCommand(queued[j])
  }

  function resetPlayback() {
    playlist = []
    playlistPos = -1
    paused = false
    muteProp = false
    aoMuteProp = false
    idle = true
    buffering = false
    position = 0
    duration = 0
    mediaTitle = ""
  }

  function handleMpvLine(line) {
    if (line.length > 1048576) return
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || typeof msg !== "object") return

    if (msg.request_id === 9000) {
      if (typeof msg.data === "number" && isFinite(msg.data)) position = msg.data
      return
    }
    if (msg.request_id === 9001) { muteProp = msg.data === true; return }
    if (msg.request_id === 9002) { aoMuteProp = msg.data === true; return }
    if (msg.request_id === 9003) {
      muteTogglePending = false
      applyMute(!(muteProp || msg.data === true))
      return
    }

    if (msg.event === "property-change") {
      var d = msg.data
      switch (msg.name) {
      case "pause": paused = d === true; if (paused) queueSave.restart(); break
      case "mute": muteProp = d === true; break
      case "ao-mute": aoMuteProp = d === true; break
      case "playlist": playlist = Array.isArray(d) ? d : []; queueSave.restart(); break
      case "playlist-pos": playlistPos = typeof d === "number" ? d : -1; queueSave.restart(); cacheLater.restart(); break
      case "duration": duration = typeof d === "number" && isFinite(d) ? d : 0; break
      case "media-title": mediaTitle = typeof d === "string" ? d : ""; break
      case "idle-active": idle = d === true; break
      case "paused-for-cache": buffering = d === true; break
      }
      return
    }

    if (msg.event === "end-file" && msg.reason === "error")
      lastError = Model.playbackError(msg, current)
    else if (msg.event === "file-loaded") {
      lastError = ""
      position = 0
      cacheLater.restart()
    }
  }

  Component {
    id: socketComponent

    Socket {
      id: s
      parser: SplitParser {
        onRead: function(line) { if (s === root.sock) root.handleMpvLine(line) }
      }
      onConnectionStateChanged: {
        if (s !== root.sock) return
        if (s.connected) {
          root.sockConnected = true
          root.onMpvConnected()
        } else {
          root.socketLost(s)
        }
      }
      onError: function(error) { root.socketLost(s) }
    }
  }

  // ---------------------------------------------------------------- player

  property bool stopping: false

  // `ytm-backend player` prepares the runtime directory and execs mpv, so
  // this Process's pid is mpv's. No detaching and no pid file: the handle
  // is the identity, and mpv goes away with this service.
  Process {
    id: playerProc
    command: ["/usr/bin/bash", root.backendPath, "player"]
    clearEnvironment: true
    environment: root.childEnvironment

    onExited: function(code) {
      playerKill.stop()
      var expected = root.stopping
      root.stopping = false
      root.starting = false
      root.pending = []
      connectRetry.stop()
      root.dropSocket()
      root.resetPlayback()
      if (!expected)
        root.lastError = "The player stopped unexpectedly. Check that mpv and yt-dlp are installed, then play the song again."
    }
  }

  Timer {
    id: playerKill
    property int stage: 0
    interval: 2000
    repeat: true
    onTriggered: {
      if (!playerProc.running) { playerKill.stop(); return }
      playerProc.signal(playerKill.stage === 0 ? 15 : 9)
      if (++playerKill.stage > 1) playerKill.stop()
    }
  }

  // mpv creates its socket a moment after it starts, so try a few times
  // before giving up.
  Timer {
    id: connectRetry
    interval: 250
    repeat: true
    onTriggered: {
      if (root.sockConnected) { connectRetry.stop(); return }
      root.connectAttempts++
      if (root.connectAttempts > 20) {
        connectRetry.stop()
        root.starting = false
        root.pending = []
        root.lastError = playerProc.running
          ? "The player started but never answered. Stop it, then play the song again."
          : "Couldn't start the player. Check that mpv is installed (omarchy pkg add mpv), then try again."
        if (playerProc.running) root.stop()
        return
      }
      root.connectSocket()
    }
  }

  // time-pos changes every frame; asking once a second is plenty for a
  // progress bar and costs nothing while paused or idle. The same tick
  // re-reads the mutes every few seconds, so a mute set from a media key
  // or the media widget shows up even though mpv's ao-mute change events
  // are not dependable.
  Timer {
    id: playPoll
    property int tick: 0
    interval: 1000
    repeat: true
    running: root.sockConnected && root.hasTrack && !root.paused
    onTriggered: {
      root.writeCommand(["get_property", "time-pos"], 9000)
      if (++playPoll.tick % 5 === 0) {
        root.writeCommand(["get_property", "mute"], 9001)
        root.writeCommand(["get_property", "ao-mute"], 9002)
      }
    }
  }

  // ---------------------------------------------------------------- saving

  property bool saveInFlight: false

  function saveQueueNow() {
    if (!sockConnected || playlist.length === 0 || saveInFlight) return
    saveInFlight = true
    runStore(["queue-put", Model.queueSnapshot(queue, playlistPos, position)], parseAny, 10, function() {
      root.saveInFlight = false
    })
  }

  // Order or current song changed: save shortly after it settles.
  Timer {
    id: queueSave
    interval: 3000
    onTriggered: root.saveQueueNow()
  }

  // While playing, save the position now and then so a restart resumes
  // close to where it was.
  Timer {
    interval: 30000
    repeat: true
    running: root.playing
    onTriggered: root.saveQueueNow()
  }

  // ---------------------------------------------------------------- cache

  // A song that has played for 20 seconds is worth keeping. A cached one
  // just gets its "last used" time refreshed.
  Timer {
    id: cacheLater
    interval: 20000
    onTriggered: {
      var t = root.current
      if (!t || !Model.isVideoId(t.id) || !root.playing) return
      if (root.cached[t.id]) { root.runStore(["cache-touch", t.id], root.parseAny, 10, function() {}); return }
      root.queueCache(t)
    }
  }

  function queueCache(track) {
    if (!cacheSongs || cacheLimitMB <= 0 || cached[track.id]) return
    for (var i = 0; i < cacheQueue.length; i++) if (cacheQueue[i].id === track.id) return
    if (cacheQueue.length >= 20) return
    cacheQueue = cacheQueue.concat([track])
    nextCache()
  }

  // One download at a time, so caching never competes with playback for
  // more than one extra stream.
  function nextCache() {
    if (caching || cacheQueue.length === 0) return
    var t = cacheQueue[0]
    cacheQueue = cacheQueue.slice(1)
    caching = true
    var limit = Math.max(1, Math.min(100000, cacheLimitMB | 0))
    runStore(["cache-fetch", String(limit), t.id, t.title || "", t.artist || "", t.album || "", t.duration || ""], Model.parseCache, 320, function(reply) {
      root.caching = false
      if (reply.ok) {
        root.cacheError = ""
        root.refreshCache()
      } else {
        root.cacheError = reply.error
      }
      root.nextCache()
    })
  }

  function refreshCache() {
    runStore(["cache-list"], Model.parseCache, 20, function(reply) {
      if (!reply.ok) { root.cacheError = reply.error; return }
      root.cachedTracks = reply.tracks
      root.cacheDir = reply.dir
      root.cacheBytes = reply.bytes
    })
  }

  function clearCache() {
    cacheQueue = []
    runStore(["cache-clear"], Model.parseCache, 30, function(reply) {
      if (reply.ok) { root.cachedTracks = []; root.cacheBytes = 0; root.cacheError = "" }
      else root.cacheError = reply.error
    })
  }

  function parseAny(text) {
    var r = Model.parseJsonReply(text)
    return r.ok ? { ok: true } : r
  }

  // ---------------------------------------------------------------- backend

  // One Process per call, so a slow search can never deliver its output into
  // a newer call. Each call runs under `timeout -k`, which kills the whole
  // process group (bash, curl, jq, head) at the deadline, and output is read
  // in raw chunks with a byte budget instead of being collected whole. The
  // helper already caps what it prints; this is the second fence.
  Component {
    id: backendRun

    Process {
      id: run
      property var callback: null
      property var parse: null
      property int deadlineMs: 30000
      property bool finished: false
      property bool overflow: false
      property string buf: ""
      property int outputLimit: root.maxReplyBytes

      clearEnvironment: true
      environment: root.childEnvironment

      function finish(reply) {
        if (finished) return
        finished = true
        watchdog.stop()
        if (callback) callback(reply)
      }

      function terminate() {
        if (!run.running) return
        run.signal(15)
        killTimer.start()
      }

      stdout: SplitParser {
        splitMarker: ""
        onRead: function(chunk) {
          if (run.overflow) return
          run.buf += chunk
          if (run.buf.length > run.outputLimit) {
            run.overflow = true
            run.buf = ""
            run.terminate()
          }
        }
      }

      onExited: function(code) {
        killTimer.stop()
        run.finish(run.overflow
          ? { ok: false, error: "The helper script returned too much data. Try again." }
          : (run.parse ? run.parse(run.buf) : Model.parseReply(run.buf)))
        run.buf = ""
        Qt.callLater(function() { run.destroy() })
      }

      property Timer watchdog: Timer {
        interval: run.deadlineMs
        running: true
        onTriggered: {
          run.finish({ ok: false, error: "The helper script took too long. Check your connection, then try again." })
          run.terminate()
        }
      }

      property Timer killTimer: Timer {
        interval: 2000
        onTriggered: if (run.running) run.signal(9)
      }
    }
  }

  function runBackend(args, callback, parse) {
    startRun(["/usr/bin/timeout", "-k", "2", "--", "25", "/usr/bin/bash", backendPath].concat(args), parse || Model.parseReply, 25, callback)
  }

  // The storage helper, with the system Python in isolated mode.
  function runStore(args, parse, seconds, callback) {
    startRun(["/usr/bin/timeout", "-k", "3", "--", String(seconds), "/usr/bin/python3", "-I", "-S", storePath].concat(args), parse, seconds, callback)
  }

  function startRun(command, parse, seconds, callback, outputLimit) {
    var run = backendRun.createObject(root, {
      command: command,
      parse: parse,
      deadlineMs: (seconds + 5) * 1000,
      outputLimit: outputLimit || root.maxReplyBytes,
      callback: callback
    })
    if (!run) { callback({ ok: false, error: "Couldn't start the helper script." }); return }
    run.running = true
  }

  // Reads only: the saved queue, search history and the cache list. The
  // helper creates nothing for these, so loading the plugin writes nothing.
  Component.onCompleted: {
    runStore(["queue-get"], Model.parseQueue, 10, function(reply) {
      if (reply.ok && reply.tracks.length > 0 && !root.sockConnected && !root.starting && root.playlist.length === 0)
        root.restored = { tracks: reply.tracks, index: reply.index, position: reply.position }
    })
    runStore(["history-get"], Model.parseHistory, 10, function(reply) {
      if (reply.ok) root.history = reply.history
    })
    refreshCache()
    scanLocalMusic()
  }

  Component.onDestruction: {
    dropSocket()
    if (playerProc.running) playerProc.signal(15)
  }
}
