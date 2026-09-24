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

console.log(`model-test: ${passed} passed`)
