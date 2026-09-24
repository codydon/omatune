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
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string socketPath: runtimeDir !== "" ? runtimeDir + "/codydon-omatune/mpv.sock" : ""

  // Children get a minimal, fixed environment rather than the shell's:
  // a fixed PATH, and only what mpv needs for audio (XDG_RUNTIME_DIR),
  // MPRIS (the session bus) and yt-dlp's cache (HOME).
  readonly property var childEnvironment: ({
    "HOME": Quickshell.env("HOME") || "",
    "XDG_RUNTIME_DIR": runtimeDir,
    "DBUS_SESSION_BUS_ADDRESS": Quickshell.env("DBUS_SESSION_BUS_ADDRESS") || "",
    "PATH": "/usr/bin",
    "LANG": "C.UTF-8"
  })
  readonly property int maxReplyBytes: 262144

  // ---- Search
  property string query: ""
  property var results: []
  property bool searching: false
  property string searchError: ""
  property int searchToken: 0

  // ---- Playback, mirrored from mpv
  property var playlist: []
  property int playlistPos: -1
  property bool paused: false
  property bool idle: true
  property bool buffering: false
  property real position: 0
  property real duration: 0
  property string mediaTitle: ""
  property var meta: Object.create(null)

  readonly property var queue: Model.buildQueue(playlist, meta)
  readonly property var current: playlistPos >= 0 && playlistPos < queue.length ? queue[playlistPos] : null
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

  // Settings the bar widget pushes in.
  property bool autoRadio: true

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
    })
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
    meta = Model.rememberTracks(meta, [track])
    var token = ++radioToken
    send(Model.loadfileCommand(track, "replace"))
    send(["set_property", "pause", false])
    if (withRadio === undefined ? autoRadio : withRadio) fillRadio(track, token)
    else radioLoading = false
  }

  function enqueue(track) {
    if (!track || !Model.isVideoId(track.id)) return
    meta = Model.rememberTracks(meta, [track])
    send(Model.loadfileCommand(track, "append"))
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
      for (var i = 0; i < additions.length; i++) root.send(Model.loadfileCommand(additions[i], "append"))
    })
  }

  function playIndex(index) {
    if (index < 0 || index >= queue.length) return
    send(["playlist-play-index", index])
    send(["set_property", "pause", false])
  }

  function removeIndex(index) {
    if (index < 0 || index >= queue.length) return
    send(["playlist-remove", index])
  }

  function clearQueue() {
    send(["playlist-clear"])
  }

  // ---------------------------------------------------------------- transport

  function togglePause() { if (hasTrack) send(["cycle", "pause"]) }
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
    if (pending.length < 200) pending = pending.concat([command])
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
    var observed = ["pause", "playlist", "playlist-pos", "duration", "media-title", "idle-active", "paused-for-cache"]
    for (var i = 0; i < observed.length; i++) writeCommand(["observe_property", i + 1, observed[i]])
    var queued = pending
    pending = []
    for (var j = 0; j < queued.length; j++) writeCommand(queued[j])
  }

  function resetPlayback() {
    playlist = []
    playlistPos = -1
    paused = false
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

    if (msg.event === "property-change") {
      var d = msg.data
      switch (msg.name) {
      case "pause": paused = d === true; break
      case "playlist": playlist = Array.isArray(d) ? d : []; break
      case "playlist-pos": playlistPos = typeof d === "number" ? d : -1; position = 0; break
      case "duration": duration = typeof d === "number" && isFinite(d) ? d : 0; break
      case "media-title": mediaTitle = typeof d === "string" ? d : ""; break
      case "idle-active": idle = d === true; break
      case "paused-for-cache": buffering = d === true; break
      }
      return
    }

    if (msg.event === "end-file" && msg.reason === "error")
      lastError = Model.playbackError(msg, current)
    else if (msg.event === "file-loaded")
      lastError = ""
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
  // progress bar and costs nothing while paused or idle.
  Timer {
    interval: 1000
    repeat: true
    running: root.sockConnected && root.hasTrack && !root.paused
    onTriggered: root.writeCommand(["get_property", "time-pos"], 9000)
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
      property bool finished: false
      property bool overflow: false
      property string buf: ""

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
          if (run.buf.length > root.maxReplyBytes) {
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
          : Model.parseReply(run.buf))
        run.buf = ""
        Qt.callLater(function() { run.destroy() })
      }

      property Timer watchdog: Timer {
        interval: 30000
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

  function runBackend(args, callback) {
    var run = backendRun.createObject(root, {
      command: ["/usr/bin/timeout", "-k", "2", "--", "25", "/usr/bin/bash", backendPath].concat(args),
      callback: callback
    })
    if (!run) { callback({ ok: false, error: "Couldn't start the helper script." }); return }
    run.running = true
  }

  Component.onDestruction: {
    dropSocket()
    if (playerProc.running) playerProc.signal(15)
  }
}
