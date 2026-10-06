// Run with: node tests/model-test.js
const assert = require("node:assert/strict")
const M = require("../Model.js")

let passed = 0
function test(name, fn) {
  fn()
  passed++
}

test("plain strips markup, controls and bidi overrides, then caps", () => {
  assert.equal(M.plain('<img src="http://x">Song\u202e & co\u0007', 100), 'img src="http://x"Song and co')
  assert.equal(M.plain("Daft Punk & Julian", 100), "Daft Punk and Julian")
  assert.equal(M.plain("abcdef", 3), "abc")
  assert.equal(M.plain(null, 5), "")
})

test("video ids and watch urls round-trip, and nothing else passes", () => {
  assert.equal(M.idFromUrl(M.watchUrl("wU26xVT_vBU")), "wU26xVT_vBU")
  assert.equal(M.watchUrl("bad;id"), "")
  assert.equal(M.idFromUrl("https://evil.example/watch?v=wU26xVT_vBU"), "")
  assert.equal(M.idFromUrl("https://music.youtube.com/watch?v=wU26xVT_vBU&x=1"), "")
})

test("parseReply accepts the documented shape and drops bad tracks", () => {
  const r = M.parseReply(JSON.stringify({ ok: true, tracks: [
    { id: "wU26xVT_vBU", title: "One More Time", artist: "Daft Punk", album: "", duration: "5:21" },
    { id: "nope", title: "x" },
    { id: "Rgrt_8mXrK8", title: "<b>Get Lucky</b>", artist: "Daft Punk", duration: "--rm" }
  ] }))
  assert.equal(r.ok, true)
  assert.equal(r.tracks.length, 2)
  assert.equal(r.tracks[1].title, "bGet Lucky/b")
  assert.equal(r.tracks[1].duration, "")
})

test("parseReply turns failures and garbage into sentences", () => {
  assert.deepEqual(M.parseReply('{"ok":false,"error":"Offline."}'), { ok: false, error: "Offline." })
  assert.equal(M.parseReply("").ok, false)
  assert.equal(M.parseReply("not json").ok, false)
  assert.equal(M.parseReply("x".repeat(300000)).ok, false)
})

test("utf8Length counts bytes like mpv does", () => {
  assert.equal(M.utf8Length("abc"), 3)
  assert.equal(M.utf8Length("—"), 3)
  assert.equal(M.utf8Length("é"), 2)
  assert.equal(M.utf8Length("🎵"), 4)
  for (const s of ["One More Time, Radio Edit — Daft", "Beyoncé 🎵 x"])
    assert.equal(M.utf8Length(s), Buffer.byteLength(s))
})

test("loadfileCommand length-prefixes the title so commas survive", () => {
  const cmd = M.loadfileCommand({ id: "wU26xVT_vBU", title: "One, Two", artist: "Daft Punk" }, "replace")
  assert.deepEqual(cmd.slice(0, 4), ["loadfile", "https://music.youtube.com/watch?v=wU26xVT_vBU", "replace", -1])
  assert.equal(cmd[4], "force-media-title=%22%One, Two — Daft Punk")
  assert.equal(M.loadfileCommand({ id: "wU26xVT_vBU", title: "x", artist: "" }, "append")[2], "append-play")
})

test("buildQueue maps mpv entries to known metadata", () => {
  const meta = M.rememberTracks(Object.create(null), [{ id: "wU26xVT_vBU", title: "One More Time", artist: "Daft Punk", duration: "5:21" }])
  const q = M.buildQueue([
    { filename: "https://music.youtube.com/watch?v=wU26xVT_vBU", current: true },
    { filename: "https://music.youtube.com/watch?v=Rgrt_8mXrK8", title: "Recovered" },
    { filename: "/home/me/song.flac" }
  ], meta)
  assert.equal(q[0].title, "One More Time")
  assert.equal(q[0].current, true)
  assert.equal(q[1].title, "Recovered")
  assert.equal(q[2].id, "")
  assert.equal(q[2].title, "/home/me/song.flac")
  assert.deepEqual(M.buildQueue(null, meta), [])
})

test("rememberTracks ignores __proto__ style keys", () => {
  const meta = M.rememberTracks(Object.create(null), [{ id: "__proto__", title: "x" }])
  assert.equal(Object.keys(meta).length, 0)
})

test("radioAdditions skips the seed and anything queued", () => {
  const queue = [{ id: "wU26xVT_vBU" }]
  const out = M.radioAdditions([{ id: "wU26xVT_vBU" }, { id: "Rgrt_8mXrK8" }, { id: "Rgrt_8mXrK8" }], queue)
  assert.deepEqual(out.map(t => t.id), ["Rgrt_8mXrK8"])
})

test("formatTime and clampIndex", () => {
  assert.equal(M.formatTime(0), "0:00")
  assert.equal(M.formatTime(65.9), "1:05")
  assert.equal(M.formatTime(3725), "1:02:05")
  assert.equal(M.formatTime(NaN), "0:00")
  assert.equal(M.clampIndex(5, 3), 2)
  assert.equal(M.clampIndex(-1, 3), 0)
  assert.equal(M.clampIndex(0, 0), -1)
})

const CACHE = "/home/me/.cache/codydon-omatune/audio"

test("cached tracks play from disk, everything else from YouTube", () => {
  const cached = M.cacheMap([{ id: "wU26xVT_vBU", ext: "webm" }])
  assert.equal(M.sourceFor({ id: "wU26xVT_vBU" }, cached, CACHE), CACHE + "/wU26xVT_vBU.webm")
  assert.equal(M.sourceFor({ id: "Rgrt_8mXrK8" }, cached, CACHE), "https://music.youtube.com/watch?v=Rgrt_8mXrK8")
  assert.equal(M.sourceFor({ id: "wU26xVT_vBU" }, cached, "relative/dir"), "https://music.youtube.com/watch?v=wU26xVT_vBU")
  assert.equal(M.sourceFor({ id: "wU26xVT_vBU" }, M.cacheMap([{ id: "wU26xVT_vBU", ext: "sh" }]), CACHE), "https://music.youtube.com/watch?v=wU26xVT_vBU")
})

test("cache directories must be plain absolute paths", () => {
  assert.equal(M.validCacheDir(CACHE), true)
  for (const bad of ["", "cache", "/a/../b", "/a/..", "/a b", "/a\nb", "/a,b", 5])
    assert.equal(M.validCacheDir(bad), false, String(bad))
})

test("idFromUrl understands cached file paths", () => {
  assert.equal(M.idFromUrl(CACHE + "/wU26xVT_vBU.webm", CACHE), "wU26xVT_vBU")
  assert.equal(M.idFromUrl(CACHE + "/wU26xVT_vBU.m4a", CACHE), "wU26xVT_vBU")
  assert.equal(M.idFromUrl(CACHE + "/wU26xVT_vBU.mp3", CACHE), "")
  assert.equal(M.idFromUrl("/elsewhere/wU26xVT_vBU.webm", CACHE), "")
  assert.equal(M.idFromUrl(CACHE + "/sub/wU26xVT_vBU.webm", CACHE), "")
})

test("loadfileCommand adds a resume offset and supports idle appends", () => {
  const t = { id: "wU26xVT_vBU", title: "One", artist: "" }
  const cmd = M.loadfileCommand(t, "append-idle", CACHE + "/wU26xVT_vBU.webm", 83.7)
  assert.deepEqual(cmd.slice(0, 4), ["loadfile", CACHE + "/wU26xVT_vBU.webm", "append", -1])
  assert.equal(cmd[4], "force-media-title=%3%One,start=83")
  assert.equal(M.loadfileCommand(t, "append-idle", "", 0.5)[4], "force-media-title=%3%One")
})

test("parseHistory, parseQueue and parseCache only accept the documented shapes", () => {
  assert.deepEqual(M.parseHistory('{"ok":true,"history":["a <b>", 5, "", "c"]}').history, ["a b", "c"])
  const q = M.parseQueue('{"ok":true,"queue":{"tracks":[{"id":"wU26xVT_vBU","title":"x"},{"id":"bad"}],"index":9,"position":-4}}')
  assert.equal(q.tracks.length, 1)
  assert.equal(q.index, 0)
  assert.equal(q.position, 0)
  const c = M.parseCache('{"ok":true,"dir":"' + CACHE + '","bytes":10,"tracks":[{"id":"wU26xVT_vBU","title":"x","ext":"webm","size":10},{"id":"Rgrt_8mXrK8","ext":"exe"}]}')
  assert.equal(c.dir, CACHE)
  assert.deepEqual(c.tracks.map(t => t.id), ["wU26xVT_vBU"])
  assert.equal(M.parseCache('{"ok":true,"dir":"../x","tracks":[]}').dir, "")
  assert.equal(M.parseCache('{"ok":true,"dir":"' + CACHE + '","cached":{"id":"wU26xVT_vBU","title":"x","ext":"m4a","size":1}}').tracks[0].ext, "m4a")
  assert.equal(M.parseQueue('{"ok":false,"error":"nope"}').ok, false)
})

test("parseSuggestions cleans, drops junk and caps at eight", () => {
  const many = []
  for (let i = 0; i < 12; i++) many.push("daft punk " + i)
  const r = M.parseSuggestions(JSON.stringify({ ok: true, suggestions: ["daft punk", 5, "", "  ", ...many] }))
  assert.equal(r.ok, true)
  assert.equal(r.suggestions.length, 8)
  assert.equal(r.suggestions[0], "daft punk")
  assert.equal(r.suggestions[7], "daft punk 6")
  assert.deepEqual(M.parseSuggestions('{"ok":true}').suggestions, [])
  assert.equal(M.parseSuggestions('{"ok":false,"error":"nope"}').ok, false)
})

test("pushHistory keeps the newest first without case-insensitive duplicates", () => {
  let h = []
  for (const q of ["daft punk", "Future", "DAFT PUNK", "  "]) h = M.pushHistory(h, q)
  assert.deepEqual(h, ["DAFT PUNK", "Future"])
  for (let i = 0; i < 80; i++) h = M.pushHistory(h, "q" + i)
  assert.equal(h.length, 50)
  assert.equal(h[0], "q79")
})

test("queueSnapshot stays under the argv limit and keeps the current song", () => {
  const rows = []
  for (let i = 0; i < 400; i++) rows.push({ id: ("A" + String(i).padStart(10, "0")).slice(0, 11), title: "T".repeat(190), artist: "A".repeat(110), duration: "3:00" })
  const snap = JSON.parse(M.queueSnapshot(rows, 350, 42.26))
  assert.ok(Buffer.byteLength(M.queueSnapshot(rows, 350, 42.26)) <= 100000)
  assert.equal(snap.tracks[snap.index].id, rows[350].id)
  assert.equal(snap.position, 42.3)
  const small = JSON.parse(M.queueSnapshot(rows.slice(0, 3), 1, NaN))
  assert.equal(small.tracks.length, 3)
  assert.equal(small.index, 1)
  assert.equal(small.position, 0)
})

test("formatBytes", () => {
  assert.equal(M.formatBytes(5319766), "5.1 MB")
  assert.equal(M.formatBytes(2 * 1073741824), "2.0 GB")
  assert.equal(M.formatBytes(-1), "")
})

test("search replies keep the track kind and YouTube's spelling fix, cleaned", () => {
  const r = M.parseReply(JSON.stringify({ ok: true, didYouMean: "zero <sugar>\u202e", showingFor: 5, tracks: [
    { id: "vdEMvr-vpdI", kind: "video", title: "Otero (Audio)", artist: "Zzero Sufuri", duration: "3:48" },
    { id: "wU26xVT_vBU", kind: "<script>", title: "One More Time" }
  ] }))
  assert.equal(r.ok, true)
  assert.deepEqual(r.tracks.map(t => t.kind), ["video", "song"])
  assert.equal(r.didYouMean, "zero sugar")
  assert.equal(r.showingFor, "")
  assert.equal(M.parseReply('{"ok":true,"tracks":[]}').didYouMean, "")
})

test("search filters cycle all, songs, videos and reject anything else", () => {
  assert.equal(M.searchFilter("videos"), "videos")
  assert.equal(M.searchFilter("--rm"), "all")
  assert.equal(M.nextSearchFilter("all"), "songs")
  assert.equal(M.nextSearchFilter("songs"), "videos")
  assert.equal(M.nextSearchFilter("videos"), "all")
  assert.equal(M.nextSearchFilter(undefined), "songs")
})

test("the queue remembers which entries are videos", () => {
  const meta = M.rememberTracks(Object.create(null), [{ id: "vdEMvr-vpdI", title: "Otero", kind: "video" }])
  const rows = M.buildQueue([{ filename: M.watchUrl("vdEMvr-vpdI") }, { filename: M.watchUrl("wU26xVT_vBU") }], meta)
  assert.deepEqual(rows.map(r => r.kind), ["video", "song"])
})

console.log(`model-test: ${passed} passed`)
