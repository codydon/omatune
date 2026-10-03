// Pure helpers for the YouTube Music plugin. No Qt, no I/O, so everything
// here runs under node (tests/model-test.js).
//
// mpv is the source of truth for the queue: its `playlist` property holds the
// order and which entry is current. This module maps those entries back to
// the track metadata the backend returned, and builds the commands the
// Service writes to mpv's JSON IPC socket.

var MAX_TITLE = 200
var MAX_ARTIST = 120
var MAX_TRACKS = 40
var MAX_QUEUE = 500
var MAX_REPLY_BYTES = 262144
var VIDEO_ID = /^[A-Za-z0-9_-]{11}$/
var WATCH_PREFIX = "https://music.youtube.com/watch?v="
var MAX_HISTORY = 50
var MAX_SUGGESTIONS = 8
var MAX_SAVED_QUEUE = 200
// One argv string can't exceed 128 KiB on Linux; stay well under it.
var MAX_SAVE_BYTES = 100000
var CACHE_EXT = /^(webm|m4a)$/
var LOCAL_EXT = /\.(aac|aiff|alac|flac|m4a|mp3|ogg|opus|wav|wma)$/i

// Control, bidi-override and markup characters are dropped before any string
// reaches a label, a tooltip or mpv's media title (which MPRIS republishes).
function plain(value, max) {
  var s = String(value === undefined || value === null ? "" : value)
  // "Daft Punk & Julian Casablancas" should survive as words, not as a gap.
  s = s.replace(/\s*&\s*/g, " and ")
  s = s.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069<>&]/g, "")
  return s.length > max ? s.slice(0, max) : s
}

function isVideoId(value) {
  return typeof value === "string" && VIDEO_ID.test(value)
}

function watchUrl(id) {
  return isVideoId(id) ? WATCH_PREFIX + id : ""
}

// The cache directory comes from the storage helper. It must be a plain
// absolute path; anything odd disables cached playback rather than being
// handed to mpv.
function validCacheDir(dir) {
  return typeof dir === "string" && /^\/[A-Za-z0-9._\/-]{1,300}$/.test(dir) && dir.indexOf("/../") < 0 && !/\/\.\.?$/.test(dir)
}

// Maps an mpv playlist filename back to a video id: our watch URLs, and
// files inside the cache directory named <id>.webm or <id>.m4a.
function idFromUrl(url, cacheDir) {
  var s = String(url || "")
  if (s.indexOf(WATCH_PREFIX) === 0) {
    var id = s.slice(WATCH_PREFIX.length)
    return isVideoId(id) ? id : ""
  }
  if (validCacheDir(cacheDir) && s.indexOf(cacheDir + "/") === 0) {
    var m = /^([A-Za-z0-9_-]{11})\.(webm|m4a)$/.exec(s.slice(cacheDir.length + 1))
    return m ? m[1] : ""
  }
  return ""
}

// Where mpv should load a track from: the cached file when there is one,
// otherwise YouTube Music.
function sourceFor(track, cached, cacheDir) {
  var hit = track && cached ? cached[track.id] : null
  if (hit && CACHE_EXT.test(hit.ext) && validCacheDir(cacheDir)) return cacheDir + "/" + track.id + "." + hit.ext
  return watchUrl(track ? track.id : "")
}

function cleanTrack(raw) {
  if (!raw || typeof raw !== "object" || !isVideoId(raw.id)) return null
  var duration = typeof raw.duration === "string" && /^\d{1,2}(:\d{2}){1,2}$/.test(raw.duration) ? raw.duration : ""
  return {
    id: raw.id,
    title: plain(raw.title, MAX_TITLE) || raw.id,
    artist: plain(raw.artist, MAX_ARTIST),
    album: plain(raw.album, MAX_ARTIST),
    duration: duration
  }
}

// Parses one line of helper output into { ok, data } or { ok: false, error }.
// Anything that is not the documented shape becomes an error rather than a
// partly-trusted object.
function parseJsonReply(text) {
  var s = String(text || "").trim()
  if (s === "") return { ok: false, error: "The helper script returned nothing. Check it is executable." }
  if (s.length > MAX_REPLY_BYTES) return { ok: false, error: "The helper script returned too much data." }
  var data
  try { data = JSON.parse(s) } catch (e) { return { ok: false, error: "The helper script returned something that isn't JSON." } }
  if (!data || typeof data !== "object" || Array.isArray(data)) return { ok: false, error: "The helper script returned an unexpected reply." }
  if (data.ok !== true) return { ok: false, error: plain(data.error, 300) || "Something went wrong." }
  return { ok: true, data: data }
}

function cleanTracks(list, max) {
  var tracks = []
  if (!Array.isArray(list)) return tracks
  for (var i = 0; i < list.length && tracks.length < max; i++) {
    var t = cleanTrack(list[i])
    if (t) tracks.push(t)
  }
  return tracks
}

// search / radio: { ok, tracks }
function parseReply(text) {
  var r = parseJsonReply(text)
  if (!r.ok) return r
  return { ok: true, tracks: cleanTracks(r.data.tracks, MAX_TRACKS) }
}

// history-*: { ok, history: [query, …] }
function parseHistory(text) {
  var r = parseJsonReply(text)
  if (!r.ok) return r
  var out = []
  var list = Array.isArray(r.data.history) ? r.data.history : []
  for (var i = 0; i < list.length && out.length < MAX_HISTORY; i++) {
    var q = plain(list[i], 200).trim()
    if (typeof list[i] === "string" && q !== "") out.push(q)
  }
  return { ok: true, history: out }
}

// suggest: { ok, suggestions: [query, …] }
function parseSuggestions(text) {
  var r = parseJsonReply(text)
  if (!r.ok) return r
  var out = []
  var list = Array.isArray(r.data.suggestions) ? r.data.suggestions : []
  for (var i = 0; i < list.length && out.length < MAX_SUGGESTIONS; i++) {
    var q = plain(list[i], 200).trim()
    if (typeof list[i] === "string" && q !== "") out.push(q)
  }
  return { ok: true, suggestions: out }
}

// queue-get: { ok, queue: { tracks, index, position } }
function parseQueue(text) {
  var r = parseJsonReply(text)
  if (!r.ok) return r
  var q = r.data.queue && typeof r.data.queue === "object" ? r.data.queue : {}
  var tracks = cleanTracks(q.tracks, MAX_SAVED_QUEUE)
  var index = Number(q.index)
  var position = Number(q.position)
  return {
    ok: true,
    tracks: tracks,
    index: Number.isInteger(index) && index >= 0 && index < tracks.length ? index : 0,
    position: isFinite(position) && position >= 0 && position < 86400 ? position : 0
  }
}

// cache-list / cache-fetch / cache-clear: { ok, dir, tracks | cached, bytes }
function parseCache(text) {
  var r = parseJsonReply(text)
  if (!r.ok) return r
  var list = Array.isArray(r.data.tracks) ? r.data.tracks : (r.data.cached ? [r.data.cached] : [])
  var tracks = []
  for (var i = 0; i < list.length && tracks.length < 300; i++) {
    var t = cleanTrack(list[i])
    var ext = list[i] ? list[i].ext : ""
    var size = Number(list[i] ? list[i].size : 0)
    if (!t || typeof ext !== "string" || !CACHE_EXT.test(ext)) continue
    t.ext = ext
    t.size = isFinite(size) && size >= 0 ? size : 0
    tracks.push(t)
  }
  var bytes = Number(r.data.bytes)
  return {
    ok: true,
    dir: validCacheDir(r.data.dir) ? r.data.dir : "",
    tracks: tracks,
    bytes: isFinite(bytes) && bytes >= 0 ? bytes : -1
  }
}

function parseLocalLibrary(text) {
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return { ok: false, error: "Couldn't read the local music scan." } }
  if (!Array.isArray(data)) return { ok: false, error: "The local music scan returned an unexpected result." }
  var tracks = []
  for (var i = 0; i < data.length; i++) {
    var t = data[i]
    if (!t || typeof t.path !== "string" || t.path.charAt(0) !== "/" || !LOCAL_EXT.test(t.path)) continue
    tracks.push({ id: t.path, path: t.path, title: plain(t.title || t.path.split("/").pop(), MAX_TITLE), artist: "", album: "", duration: "", local: true })
  }
  return { ok: true, tracks: tracks }
}

function localFileCommand(track, mode) {
  if (!track || !track.local || typeof track.path !== "string" || track.path.charAt(0) !== "/" || !LOCAL_EXT.test(track.path)) return null
  return ["loadfile", track.path, mode === "replace" ? "replace" : "append"]
}

function cacheMap(tracks) {
  var map = Object.create(null)
  for (var i = 0; i < tracks.length; i++) map[tracks[i].id] = tracks[i]
  return map
}

function formatBytes(n) {
  var v = Number(n)
  if (!isFinite(v) || v < 0) return ""
  if (v < 1024 * 1024) return Math.round(v / 1024) + " KB"
  if (v < 1024 * 1024 * 1024) return (v / 1048576).toFixed(v < 10485760 ? 1 : 0) + " MB"
  return (v / 1073741824).toFixed(1) + " GB"
}

// Search history, most recent first, without case-insensitive duplicates.
function pushHistory(history, query) {
  var q = plain(query, 200).trim()
  if (q === "") return history.slice(0, MAX_HISTORY)
  var out = [q]
  for (var i = 0; i < history.length && out.length < MAX_HISTORY; i++)
    if (history[i].toLowerCase() !== q.toLowerCase()) out.push(history[i])
  return out
}

// The queue as saved to disk. When it would be too big for one argv
// string, keep a window of songs around the current one.
function queueSnapshot(rows, index, position) {
  var tracks = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r && isVideoId(r.id)) tracks.push({ id: r.id, title: r.title, artist: r.artist || "", album: r.album || "", duration: r.duration || "" })
  }
  var at = Math.max(0, Math.min(tracks.length - 1, index | 0))
  var start = Math.max(0, at - 20)
  var end = Math.min(tracks.length, start + MAX_SAVED_QUEUE)
  var pos = Number(position)
  pos = isFinite(pos) && pos > 0 ? Math.round(pos * 10) / 10 : 0
  for (;;) {
    var text = JSON.stringify({ tracks: tracks.slice(start, end), index: at - start, position: pos })
    if (utf8Length(text) <= MAX_SAVE_BYTES || end - start <= 1) return text
    end = start + Math.max(1, Math.floor((end - start) * 0.75))
    if (at >= end) { start = at; end = at + 1 }
  }
}

function displayTitle(track) {
  if (!track) return ""
  return track.artist ? track.title + " — " + track.artist : track.title
}

// mpv's per-file option list is comma separated, so a title with a comma
// would split the option. The %N% prefix tells mpv the value is exactly N
// bytes long; N must be UTF-8 bytes, not UTF-16 code units.
function utf8Length(s) {
  var n = 0
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) { n += 4; i++ }
    else n += 3
  }
  return n
}

// `source` defaults to the watch URL; `startSeconds` resumes part-way in.
function loadfileCommand(track, mode, source, startSeconds) {
  var title = plain(displayTitle(track), MAX_TITLE + MAX_ARTIST + 3)
  // "append-idle" adds without starting playback (used when restoring).
  var flags = mode === "replace" ? "replace" : (mode === "append-idle" ? "append" : "append-play")
  var options = ["force-media-title=%" + utf8Length(title) + "%" + title]
  var start = Number(startSeconds)
  if (isFinite(start) && start >= 1) options.push("start=" + Math.floor(start))
  return ["loadfile", source || watchUrl(track.id), flags, -1, options.join(",")]
}

function rememberTracks(meta, tracks) {
  var next = Object.create(null)
  for (var key in meta) next[key] = meta[key]
  for (var i = 0; i < tracks.length; i++) if (tracks[i] && isVideoId(tracks[i].id)) next[tracks[i].id] = tracks[i]
  return next
}

// Turns mpv's playlist into rows for the panel. Entries that are not our
// watch URLs (something else loaded into this mpv) are shown by filename.
function buildQueue(playlist, meta, cacheDir) {
  var rows = []
  if (!Array.isArray(playlist)) return rows
  for (var i = 0; i < playlist.length && i < MAX_QUEUE; i++) {
    var entry = playlist[i] || {}
    var id = idFromUrl(entry.filename, cacheDir)
    var known = id && meta ? meta[id] : null
    rows.push({
      index: i,
      id: id,
      path: !id && typeof entry.filename === "string" && entry.filename.charAt(0) === "/" ? entry.filename : "",
      local: !id && typeof entry.filename === "string" && entry.filename.charAt(0) === "/" && LOCAL_EXT.test(entry.filename),
      title: known ? known.title : plain(entry.title || entry.filename || "Unknown track", MAX_TITLE),
      artist: known ? known.artist : "",
      album: known ? known.album : "",
      duration: known ? known.duration : "",
      current: entry.current === true
    })
  }
  return rows
}

// Radio results start with the seed song itself; skip it and anything that
// is already queued so "start radio" never repeats a track.
function radioAdditions(tracks, queue) {
  var seen = Object.create(null)
  for (var i = 0; i < queue.length; i++) if (queue[i].id) seen[queue[i].id] = true
  var out = []
  for (var j = 0; j < tracks.length; j++) {
    var t = tracks[j]
    if (!t || seen[t.id]) continue
    seen[t.id] = true
    out.push(t)
  }
  return out
}

function formatTime(seconds) {
  var s = Number(seconds)
  if (!isFinite(s) || s < 0) return "0:00"
  s = Math.floor(s)
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  var mm = h > 0 && m < 10 ? "0" + m : String(m)
  return (h > 0 ? h + ":" : "") + mm + ":" + (sec < 10 ? "0" + sec : sec)
}

function clampIndex(index, length) {
  if (length <= 0) return -1
  return Math.max(0, Math.min(length - 1, index))
}

// Human sentence for an mpv end-file error. The raw file_error is mpv's own
// short string ("loading failed", "unrecognized file format").
function playbackError(event, track) {
  var name = track ? track.title : "this track"
  return "Couldn't play " + plain(name, 80) + ". YouTube may have changed something; update yt-dlp, then try again."
}

if (typeof module !== "undefined") {
  module.exports = {
    plain: plain, isVideoId: isVideoId, watchUrl: watchUrl, idFromUrl: idFromUrl,
    parseLocalLibrary: parseLocalLibrary, localFileCommand: localFileCommand,
    validCacheDir: validCacheDir, sourceFor: sourceFor, parseHistory: parseHistory,
    parseSuggestions: parseSuggestions,
    parseQueue: parseQueue, parseCache: parseCache, cacheMap: cacheMap,
    formatBytes: formatBytes, pushHistory: pushHistory, queueSnapshot: queueSnapshot,
    cleanTrack: cleanTrack, parseReply: parseReply, displayTitle: displayTitle,
    utf8Length: utf8Length, loadfileCommand: loadfileCommand, rememberTracks: rememberTracks,
    buildQueue: buildQueue, radioAdditions: radioAdditions, formatTime: formatTime,
    clampIndex: clampIndex, playbackError: playbackError
  }
}
