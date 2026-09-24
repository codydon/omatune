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

function idFromUrl(url) {
  var s = String(url || "")
  if (s.indexOf(WATCH_PREFIX) !== 0) return ""
  var id = s.slice(WATCH_PREFIX.length)
  return isVideoId(id) ? id : ""
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

// Parses one line of backend output. Anything that is not the documented
// shape becomes an error rather than a partly-trusted object.
function parseReply(text) {
  var s = String(text || "").trim()
  if (s === "") return { ok: false, error: "The helper script returned nothing. Check it is executable." }
  if (s.length > MAX_REPLY_BYTES) return { ok: false, error: "The helper script returned too much data." }
  var data
  try { data = JSON.parse(s) } catch (e) { return { ok: false, error: "The helper script returned something that isn't JSON." } }
  if (!data || typeof data !== "object") return { ok: false, error: "The helper script returned an unexpected reply." }
  if (data.ok !== true) return { ok: false, error: plain(data.error, 300) || "Something went wrong." }
  var tracks = []
  if (Array.isArray(data.tracks)) {
    for (var i = 0; i < data.tracks.length && tracks.length < MAX_TRACKS; i++) {
      var t = cleanTrack(data.tracks[i])
      if (t) tracks.push(t)
    }
  }
  return { ok: true, tracks: tracks }
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

function loadfileCommand(track, mode) {
  var title = plain(displayTitle(track), MAX_TITLE + MAX_ARTIST + 3)
  var flags = mode === "replace" ? "replace" : "append-play"
  return ["loadfile", watchUrl(track.id), flags, -1, "force-media-title=%" + utf8Length(title) + "%" + title]
}

function rememberTracks(meta, tracks) {
  var next = Object.create(null)
  for (var key in meta) next[key] = meta[key]
  for (var i = 0; i < tracks.length; i++) if (tracks[i] && isVideoId(tracks[i].id)) next[tracks[i].id] = tracks[i]
  return next
}

// Turns mpv's playlist into rows for the panel. Entries that are not our
// watch URLs (something else loaded into this mpv) are shown by filename.
function buildQueue(playlist, meta) {
  var rows = []
  if (!Array.isArray(playlist)) return rows
  for (var i = 0; i < playlist.length && i < MAX_QUEUE; i++) {
    var entry = playlist[i] || {}
    var id = idFromUrl(entry.filename)
    var known = id && meta ? meta[id] : null
    rows.push({
      index: i,
      id: id,
      title: known ? known.title : plain(entry.title || entry.filename || "Unknown track", MAX_TITLE),
      artist: known ? known.artist : "",
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
    cleanTrack: cleanTrack, parseReply: parseReply, displayTitle: displayTitle,
    utf8Length: utf8Length, loadfileCommand: loadfileCommand, rememberTracks: rememberTracks,
    buildQueue: buildQueue, radioAdditions: radioAdditions, formatTime: formatTime,
    clampIndex: clampIndex, playbackError: playbackError
  }
}
