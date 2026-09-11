const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

function loc(iso, country, city, ping, extra) {
  var o = { iso: iso, country: country, city: city, cliName: city, pingMs: ping, virtual: false, lat: 0, lon: 0 }
  if (extra) for (var k in extra) o[k] = extra[k]
  return o
}

test("toList handles null, arrays and array-likes", () => {
  assert.deepEqual(Model.toList(null), [])
  assert.deepEqual(Model.toList(undefined), [])
  assert.deepEqual(Model.toList([1, 2]), [1, 2])
  assert.deepEqual(Model.toList({ length: 2, 0: "a", 1: "b" }), ["a", "b"])
  assert.deepEqual(Model.toList("nope"), [])
})

test("normalizeSnapshot fills safe defaults and keeps known fields", () => {
  const empty = Model.normalizeSnapshot(null)
  assert.equal(empty.ok, false)
  assert.equal(empty.state, "unknown")
  assert.equal(empty.location, "")
  assert.equal(empty.iso, "")
  assert.equal(empty.iface, "")
  assert.equal(empty.endpoint, null)
  assert.equal(empty.sinceEpoch, 0)
  assert.equal(empty.rx, 0)
  assert.equal(empty.tx, 0)
  assert.equal(empty.error, "")
  assert.equal(empty.code, "")

  const full = Model.normalizeSnapshot({
    ok: true, state: "connected", location: "Tel Aviv", iso: "IL", iface: "tun0",
    endpoint: { ip: "1.2.3.4", port: 443, pingMs: 44 }, sinceEpoch: 1700000000, rx: 10, tx: 20
  })
  assert.equal(full.ok, true)
  assert.equal(full.state, "connected")
  assert.equal(full.location, "Tel Aviv")
  assert.equal(full.iso, "IL")
  assert.deepEqual(full.endpoint, { ip: "1.2.3.4", port: 443, pingMs: 44 })
  assert.equal(full.sinceEpoch, 1700000000)
  assert.equal(full.rx, 10)
  assert.equal(full.tx, 20)

  const err = Model.normalizeSnapshot({ ok: false, error: "boom", code: "timeout" })
  assert.equal(err.ok, false)
  assert.equal(err.error, "boom")
  assert.equal(err.code, "timeout")
  assert.equal(Model.normalizeSnapshot({ ok: true, state: "bogus" }).state, "unknown")
})

test("normalizeSnapshot never reads unparseable status as disconnected", () => {
  // agvpn.py emits state "unknown" when the CLI exits 0 with output it cannot parse.
  assert.equal(Model.normalizeSnapshot({ ok: true, state: "unknown" }).state, "unknown")
  assert.equal(Model.normalizeSnapshot({ ok: true }).state, "unknown")
  for (const s of ["connected", "connecting", "disconnected", "logged_out"])
    assert.equal(Model.normalizeSnapshot({ ok: true, state: s }).state, s)
})

test("normalizeLocations sorts by ping with nulls last and copies fields", () => {
  const out = Model.normalizeLocations({ ok: true, locations: [
    { iso: "IN", country: "India", city: "Mumbai", cliName: "Mumbai (Virtual)", pingMs: null, virtual: true, lat: 19.08, lon: 72.88 },
    { iso: "US", country: "United States", city: "New York", cliName: "New York", pingMs: 23, virtual: false, lat: 40.71, lon: -74.01 },
    { iso: "CA", country: "Canada", city: "Montreal", cliName: "Montreal", pingMs: 15, virtual: false, lat: 45.5, lon: -73.57 }
  ] })
  assert.deepEqual(out.map(l => l.city), ["Montreal", "New York", "Mumbai"])
  assert.equal(out[2].cliName, "Mumbai (Virtual)")
  assert.equal(out[2].virtual, true)
  assert.equal(out[2].pingMs, null)
  assert.equal(out[0].lat, 45.5)
  assert.deepEqual(Model.normalizeLocations(null), [])
  assert.deepEqual(Model.normalizeLocations({ ok: false }), [])
})

test("normalizeLocations defaults cliName to city and coerces types", () => {
  const out = Model.normalizeLocations({ locations: [{ iso: "de", country: "Germany", city: "Berlin", pingMs: "31" }] })
  assert.equal(out[0].iso, "DE")
  assert.equal(out[0].cliName, "Berlin")
  assert.equal(out[0].pingMs, 31)
  assert.equal(out[0].virtual, false)
  assert.equal(out[0].lat, null)
  assert.equal(out[0].lon, null)
})

test("locationKey joins ISO and city", () => {
  assert.equal(Model.locationKey(loc("IL", "Israel", "Tel Aviv", 44)), "IL|Tel Aviv")
  assert.equal(Model.locationKey(null), "")
})

test("orderLocations pins favorites in favorites order and flags last-used", () => {
  const list = [loc("CA", "Canada", "Montreal", 15), loc("US", "United States", "New York", 23), loc("IL", "Israel", "Tel Aviv", 140), loc("ES", "Spain", "Madrid", 60)]
  const out = Model.orderLocations(list, ["ES|Madrid", "IL|Tel Aviv", "XX|Nowhere"], "New York")
  assert.deepEqual(out.map(l => l.city), ["Madrid", "Tel Aviv", "Montreal", "New York"])
  assert.deepEqual(out.map(l => l.favorite), [true, true, false, false])
  assert.deepEqual(out.map(l => l.last), [false, false, false, true])
  assert.equal(list[0].favorite, undefined, "input must not be mutated")
  assert.deepEqual(Model.orderLocations(list, null, "").map(l => l.city), ["Montreal", "New York", "Tel Aviv", "Madrid"])
})

test("orderLocations' lastLocation only sets a flag, never the order", () => {
  // What makes Panel.qml's frozen `orderLast` safe: whatever the last-connected
  // city is, the rows and their indexes are identical, so a value one panel-open
  // old can never move a row out from under the keyboard cursor.
  const list = [loc("CA", "Canada", "Montreal", 15), loc("US", "United States", "New York", 23),
    loc("IL", "Israel", "Tel Aviv", 140), loc("ES", "Spain", "Madrid", 60)]
  const favs = ["ES|Madrid", "IL|Tel Aviv"]
  const base = Model.orderLocations(list, favs, "")
  for (const last of ["", "New York", "Madrid", "Montreal", "Nowhere"]) {
    const out = Model.orderLocations(list, favs, last)
    assert.deepEqual(out.map(l => l.city), base.map(l => l.city), "order with last=" + last)
    assert.deepEqual(out.map(l => l.favorite), base.map(l => l.favorite))
    assert.deepEqual(out.map(l => l.last), out.map(l => l.city === last))
  }
  // And the same holds for the filtered rows the ListView actually shows.
  assert.deepEqual(Model.filterLocations(Model.orderLocations(list, favs, "Madrid"), "a").map(l => l.city),
    Model.filterLocations(base, "a").map(l => l.city))
})

test("Panel.qml freezes both ordering inputs for as long as the panel is open", () => {
  const fs = require("node:fs"), path = require("node:path")
  const panel = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")
  // Neither the live `favorites` nor the live `lastLocation` may reach
  // orderLocations: both change while the panel is open (starring a row,
  // clicking a row) and would rebuild the list under the cursor.
  assert.match(panel, /orderedLocations: Model\.orderLocations\(vpn\.locations, orderFavorites, orderLast\)/)
  const open = /onOpenedChanged:\s*\{[\s\S]*?\n  \}/.exec(panel)
  assert.ok(open, "onOpenedChanged present")
  assert.match(open[0], /orderFavorites = favorites/)
  assert.match(open[0], /orderLast = lastLocation/)
})

test("filterLocations ignores case and diacritics across city, country and iso", () => {
  const list = [loc("BR", "Brazil", "São Paulo", 200), loc("MD", "Moldova", "Chișinău", 50), loc("GB", "United Kingdom", "London", 30), loc("US", "United States", "New York", 23)]
  assert.deepEqual(Model.filterLocations(list, "sao").map(l => l.city), ["São Paulo"])
  assert.deepEqual(Model.filterLocations(list, "CHIS").map(l => l.city), ["Chișinău"])
  assert.deepEqual(Model.filterLocations(list, "kingdom").map(l => l.city), ["London"])
  assert.deepEqual(Model.filterLocations(list, "us").map(l => l.city), ["New York"])
  assert.equal(Model.filterLocations(list, "  ").length, 4)
  assert.equal(Model.filterLocations(list, "").length, 4)
  assert.equal(Model.filterLocations(list, "zzz").length, 0)
})

test("filterLocations answers the same with or without the pre-folded hay field", () => {
  const raw = [
    { iso: "br", country: "Brazil", city: "São Paulo", pingMs: 200 },
    { iso: "md", country: "Moldova", city: "Chișinău", pingMs: 50 },
    { iso: "de", country: "Germany", city: "Berlin", pingMs: 31 },
    { iso: "ch", country: "Switzerland", city: "Zürich", pingMs: 20 },
    { iso: "c1", country: "Cloudland", city: "Nowhere", pingMs: null }
  ]
  // normalizeLocations pre-folds `hay`; the same rows stripped of it must take
  // the fallback path in filterLocations and come out identical.
  const folded = Model.normalizeLocations({ ok: true, locations: raw })
  for (const l of folded) assert.equal(typeof l.hay, "string")
  const bare = folded.map(l => {
    const copy = Object.assign({}, l)
    delete copy.hay
    return copy
  })
  for (const q of ["", "b", "ber", "zur", "zür", "C1", "  ", "zzz", "switzer"]) {
    assert.deepEqual(
      Model.filterLocations(folded, q).map(l => l.city),
      Model.filterLocations(bare, q).map(l => l.city),
      "query " + JSON.stringify(q))
  }
  // The two spellings of Zürich both reach the row, from either path.
  assert.deepEqual(Model.filterLocations(folded, "zur").map(l => l.city), ["Zürich"])
  assert.deepEqual(Model.filterLocations(folded, "zür").map(l => l.city), ["Zürich"])
  assert.deepEqual(Model.filterLocations(folded, "C1").map(l => l.city), ["Nowhere"])
})

test("a location without hay still matches city, country and iso", () => {
  const list = [loc("GB", "United Kingdom", "London", 30)]
  assert.equal(list[0].hay, undefined)
  assert.deepEqual(Model.filterLocations(list, "lond").map(l => l.city), ["London"])
  assert.deepEqual(Model.filterLocations(list, "kingdom").map(l => l.city), ["London"])
  assert.deepEqual(Model.filterLocations(list, "gb").map(l => l.city), ["London"])
  assert.equal(Model.filterLocations(list, "zzz").length, 0)
  // A junk row must be skipped, not throw.
  assert.equal(Model.filterLocations([null, {}], "x").length, 0)
})

test("copyLocation and orderLocations carry the pre-folded hay through", () => {
  const list = Model.normalizeLocations({ ok: true, locations: [
    { iso: "ch", country: "Switzerland", city: "Zürich", pingMs: 20 },
    { iso: "de", country: "Germany", city: "Berlin", pingMs: 31 }
  ] })
  const ordered = Model.orderLocations(list, ["DE|Berlin"], "Zürich")
  assert.deepEqual(ordered.map(l => l.city), ["Berlin", "Zürich"])
  for (const l of ordered) assert.equal(typeof l.hay, "string")
  assert.deepEqual(Model.filterLocations(ordered, "zur").map(l => l.city), ["Zürich"])
  // sameLocations ignores hay, and cannot be fooled by it: city/country/iso
  // are compared, and hay is derived from exactly those.
  assert.equal(Model.sameLocations(list, list.map(l => Object.assign({}, l, { hay: "garbage" }))), true)
})

test("foldText strips diacritics with and without String.normalize", () => {
  assert.equal(Model.foldText("São Paulo"), "sao paulo")
  assert.equal(Model.foldText("Chișinău"), "chisinau")
  assert.equal(Model.foldText("Chișinău", false), "chisinau")
  assert.equal(Model.foldText("Győr Kőszeg Târgu", false), "gyor koszeg targu")
})

test("toggleFavorite adds, removes, never mutates and caps at 16", () => {
  const a = Model.toggleFavorite([], "IL|Tel Aviv")
  assert.deepEqual(a, ["IL|Tel Aviv"])
  const b = Model.toggleFavorite(a, "ES|Madrid")
  assert.deepEqual(b, ["IL|Tel Aviv", "ES|Madrid"])
  assert.deepEqual(a, ["IL|Tel Aviv"])
  assert.deepEqual(Model.toggleFavorite(b, "IL|Tel Aviv"), ["ES|Madrid"])
  var many = []
  for (var i = 0; i < 16; i++) many.push("K" + i)
  const capped = Model.toggleFavorite(many, "K16")
  assert.equal(capped.length, 16)
  assert.equal(capped[0], "K1")
  assert.equal(capped[15], "K16")
  assert.deepEqual(Model.toggleFavorite(null, "A"), ["A"])
  assert.deepEqual(Model.toggleFavorite(["A"], ""), ["A"])
})

test("pingTier buckets latency", () => {
  assert.equal(Model.pingTier(0), "good")
  assert.equal(Model.pingTier(59), "good")
  assert.equal(Model.pingTier(60), "ok")
  assert.equal(Model.pingTier(149), "ok")
  assert.equal(Model.pingTier(150), "poor")
  assert.equal(Model.pingTier(1224), "poor")
  assert.equal(Model.pingTier(null), "none")
  assert.equal(Model.pingTier(undefined), "none")
  assert.equal(Model.pingTier(NaN), "none")
})

test("formatRate stays within four characters", () => {
  assert.equal(Model.formatRate(0), "0")
  assert.equal(Model.formatRate(512), "512")
  assert.equal(Model.formatRate(1023), "1023")
  assert.equal(Model.formatRate(1229), "1.2K")
  assert.equal(Model.formatRate(340 * 1024), "340K")
  assert.equal(Model.formatRate(1.2 * 1024 * 1024), "1.2M")
  assert.equal(Model.formatRate(2 * 1024 * 1024 * 1024), "2.0G")
  assert.equal(Model.formatRate(-5), "0")
  assert.equal(Model.formatRate(NaN), "0")
  const samples = [1, 9.9 * 1024, 10 * 1024, 99.5 * 1024, 999 * 1024, 1023.9 * 1024, 55 * 1024 * 1024]
  samples.forEach(s => assert.ok(Model.formatRate(s).length <= 4, Model.formatRate(s)))
})

test("formatUptime picks the two most significant units", () => {
  const now = 1700000000 * 1000
  assert.equal(Model.formatUptime(1700000000 - 42, now), "42s")
  assert.equal(Model.formatUptime(1700000000 - 7 * 60 - 3, now), "7m")
  assert.equal(Model.formatUptime(1700000000 - (2 * 3600 + 14 * 60 + 9), now), "2h 14m")
  assert.equal(Model.formatUptime(1700000000 - (3 * 86400 + 2 * 3600 + 5 * 60), now), "3d 2h")
  assert.equal(Model.formatUptime(0, now), "")
  assert.equal(Model.formatUptime(null, now), "")
  assert.equal(Model.formatUptime(1700000000 + 100, now), "0s")
})

test("rateFrom computes bytes per second and guards resets", () => {
  assert.deepEqual(Model.rateFrom({ rx: 1000, tx: 500 }, { rx: 3000, tx: 700 }, 2000), { down: 1000, up: 100 })
  assert.deepEqual(Model.rateFrom(null, { rx: 3000, tx: 700 }, 2000), { down: 0, up: 0 })
  assert.deepEqual(Model.rateFrom({ rx: 5000, tx: 900 }, { rx: 3000, tx: 700 }, 2000), { down: 0, up: 0 })
  assert.deepEqual(Model.rateFrom({ rx: 1, tx: 1 }, { rx: 5, tx: 5 }, 0), { down: 0, up: 0 })
})

test("barLabel renders per mode only while connected", () => {
  const connected = { state: "connected", iso: "IL" }
  const off = { state: "disconnected", iso: "" }
  const rates = { down: 1.2 * 1024 * 1024, up: 88 * 1024 }
  assert.equal(Model.barLabel("icon", connected, rates), "")
  assert.equal(Model.barLabel("iso", connected, rates), "IL")
  assert.equal(Model.barLabel("iso", off, rates), "")
  assert.equal(Model.barLabel("rate", connected, rates), "↓1.2M ↑88K")
  assert.equal(Model.barLabel("rate", connected, null), "↓0 ↑0")
  assert.equal(Model.barLabel("rate", off, rates), "")
  assert.equal(Model.barLabel("bogus", connected, rates), "")
})

test("nextBarMode cycles icon → iso → rate → icon", () => {
  assert.equal(Model.nextBarMode("icon"), "iso")
  assert.equal(Model.nextBarMode("iso"), "rate")
  assert.equal(Model.nextBarMode("rate"), "icon")
  assert.equal(Model.nextBarMode("bogus"), "icon")
  assert.equal(Model.nextBarMode(undefined), "icon")
})

test("heroMeta joins country, ping and uptime, omitting what is missing", () => {
  const now = 1700000000 * 1000
  const lookup = function (iso) { return iso === "IL" ? "Israel" : "" }
  const snap = { state: "connected", iso: "IL", endpoint: { pingMs: 44 }, sinceEpoch: 1700000000 - (2 * 3600 + 14 * 60) }
  assert.equal(Model.heroMeta(snap, now, lookup), "Israel · 44 ms · 2h 14m")
  assert.equal(Model.heroMeta({ state: "connected", iso: "IL", endpoint: null, sinceEpoch: 0 }, now, lookup), "Israel")
  assert.equal(Model.heroMeta({ state: "connected", iso: "XX", endpoint: { pingMs: 9 }, sinceEpoch: 0 }, now, lookup), "9 ms")
  assert.equal(Model.heroMeta({ state: "disconnected" }, now, lookup), "")
  assert.equal(Model.heroMeta({ state: "connected", iso: "IL" }, now, null), "")
})

test("homeFromTimezone uses the table and falls back to central Europe", () => {
  assert.deepEqual(Model.homeFromTimezone("Asia/Tokyo"), { lat: 35.68, lon: 139.69 })
  assert.deepEqual(Model.homeFromTimezone("America/New_York"), { lat: 40.71, lon: -74.01 })
  assert.deepEqual(Model.homeFromTimezone("US/Eastern"), { lat: 40.71, lon: -74.01 })
  assert.deepEqual(Model.homeFromTimezone("Europe/Stockholm_Custom"), { lat: 59.33, lon: 18.07 })
  assert.deepEqual(Model.homeFromTimezone("Mars/Olympus"), { lat: 48, lon: 10 })
  assert.deepEqual(Model.homeFromTimezone(""), { lat: 48, lon: 10 })
  assert.deepEqual(Model.homeFromTimezone(null), { lat: 48, lon: 10 })
})

test("normalizeTimezone strips zoneinfo/posix/right path prefixes and whitespace", () => {
  assert.equal(Model.normalizeTimezone("/usr/share/zoneinfo/Asia/Tokyo"), "Asia/Tokyo")
  assert.equal(Model.normalizeTimezone("/usr/share/zoneinfo/posix/Asia/Tokyo"), "Asia/Tokyo")
  assert.equal(Model.normalizeTimezone("posix/Asia/Tokyo"), "Asia/Tokyo")
  assert.equal(Model.normalizeTimezone("right/Asia/Tokyo"), "Asia/Tokyo")
  assert.equal(Model.normalizeTimezone("Asia/Tokyo\n"), "Asia/Tokyo")
  assert.equal(Model.normalizeTimezone("  Asia/Tokyo  "), "Asia/Tokyo")
  assert.equal(Model.normalizeTimezone("Europe/Berlin"), "Europe/Berlin")
  assert.equal(Model.normalizeTimezone(""), "")
  assert.equal(Model.normalizeTimezone(null), "")
})

test("homeFromTimezone resolves full zoneinfo paths and stays region-anchored, not a loose substring match", () => {
  assert.deepEqual(Model.homeFromTimezone("/usr/share/zoneinfo/Asia/Tokyo"), { lat: 35.68, lon: 139.69 })
  // The bug: a full path never matched TZ_TABLE, so Tokyo fell all the way
  // back to central Europe.
  assert.deepEqual(Model.homeFromTimezone("/usr/share/zoneinfo/Europe/Berlin"), { lat: 52.52, lon: 13.41 })
  assert.deepEqual(Model.homeFromTimezone("/usr/share/zoneinfo/America/New_York"), { lat: 40.71, lon: -74.01 })
  // The bug: Pacific/Auckland used to hit the loose "Pacific" fallback rule
  // and land in Los Angeles instead of its own real coordinates.
  assert.deepEqual(Model.homeFromTimezone("/usr/share/zoneinfo/Pacific/Auckland"), { lat: -36.85, lon: 174.76 })
  assert.deepEqual(Model.homeFromTimezone("posix/Asia/Tokyo"), { lat: 35.68, lon: 139.69 })
  assert.deepEqual(Model.homeFromTimezone("right/Asia/Tokyo"), { lat: 35.68, lon: 139.69 })
  assert.deepEqual(Model.homeFromTimezone("Asia/Tokyo\n"), { lat: 35.68, lon: 139.69 }, "trailing newline")
  assert.deepEqual(Model.homeFromTimezone("UTC"), { lat: 0, lon: 0 }, "bare name that is a real table key")
  assert.deepEqual(Model.homeFromTimezone("Tokyo"), { lat: 48, lon: 10 }, "bare city with no region falls back")
  assert.deepEqual(Model.homeFromTimezone("not a real timezone"), { lat: 48, lon: 10 }, "garbage falls back")
})

test("elideStatus collapses whitespace and caps length", () => {
  assert.equal(Model.elideStatus("  a \n b  "), "a b")
  assert.equal(Model.elideStatus(null), "")
  const long = new Array(200).join("x")
  assert.equal(Model.elideStatus(long).length, 140)
  assert.ok(Model.elideStatus(long).slice(-1) === "…")
  assert.equal(Model.elideStatus("abcdef", 4), "abc…")
})

test("clampInt parses and clamps settings values", () => {
  assert.equal(Model.clampInt("45", 30, 5, 3600), 45)
  assert.equal(Model.clampInt("abc", 30, 5, 3600), 30)
  assert.equal(Model.clampInt(1, 30, 5, 3600), 5)
  assert.equal(Model.clampInt(99999, 30, 5, 3600), 3600)
  assert.equal(Model.clampInt(null, 30, 5, 3600), 30)
})

test("findLocation matches a city case-insensitively, else null", () => {
  const list = [loc("IL", "Israel", "Tel Aviv", 44), loc("CA", "Canada", "Montreal", 15)]
  assert.equal(Model.findLocation(list, "montreal").iso, "CA")
  assert.equal(Model.findLocation(list, "TEL AVIV").city, "Tel Aviv")
  assert.equal(Model.findLocation(list, "Nowhere"), null)
  assert.equal(Model.findLocation(list, ""), null)
  assert.equal(Model.findLocation(null, "Montreal"), null)
})

test("normalizeAccount maps helper fields and defaults, loggedOutAccount is the empty form", () => {
  const a = Model.normalizeAccount({ ok: true, loggedIn: true, email: "u@example.com", plan: "PREMIUM", devices: 10, validUntil: "2031-01-01" })
  assert.deepEqual(a, { loggedIn: true, email: "u@example.com", plan: "PREMIUM", devices: 10, validUntil: "2031-01-01" })
  const b = Model.normalizeAccount({ ok: true, loggedIn: false })
  assert.deepEqual(b, Model.loggedOutAccount())
  assert.deepEqual(Model.loggedOutAccount(), { loggedIn: false, email: "", plan: "", devices: null, validUntil: null })
})

test("normalizeExclusions lowercases the mode, keeps unique trimmed domains in order", () => {
  const e = Model.normalizeExclusions({ ok: true, mode: "SELECTIVE", domains: [" a.com ", "b.org", "a.com", ""] })
  assert.deepEqual(e, { mode: "selective", domains: ["a.com", "b.org"] })
  assert.deepEqual(Model.normalizeExclusions(null), { mode: "general", domains: [] })
  assert.equal(Model.normalizeExclusions({ mode: "weird" }).mode, "general")
})

test("isFavorite checks a location against the favorites keys", () => {
  const favs = ["US|New York", "IL|Tel Aviv"]
  assert.equal(Model.isFavorite(favs, loc("US", "United States", "New York", 20)), true)
  assert.equal(Model.isFavorite(favs, loc("CA", "Canada", "Montreal", 15)), false)
  assert.equal(Model.isFavorite(null, loc("US", "United States", "New York", 20)), false)
  assert.equal(Model.isFavorite(favs, null), false)
})

test("normalizeConfig maps helper fields with safe defaults", () => {
  const c = Model.normalizeConfig({ mode: "SOCKS", socksHost: "127.0.0.1", socksPort: "1085", socksUsername: "u",
    dns: "1.1.1.1", changeSystemDns: true, protocol: "QUIC", postQuantum: false, showHints: false })
  assert.deepEqual(c, { mode: "socks", socksHost: "127.0.0.1", socksPort: 1085, socksUsername: "u", dns: "1.1.1.1",
    changeSystemDns: true, protocol: "quic", postQuantum: false, showHints: false })
  const d = Model.normalizeConfig(null)
  assert.deepEqual(d, { mode: "tun", socksHost: "", socksPort: 1080, socksUsername: "", dns: "default",
    changeSystemDns: false, protocol: "auto", postQuantum: true, showHints: true })
  const g = Model.normalizeConfig({ mode: "weird", protocol: "spdy", socksPort: "abc", dns: "" })
  assert.equal(g.mode, "tun")
  assert.equal(g.protocol, "auto")
  assert.equal(g.socksPort, 1080)
  assert.equal(g.dns, "default")
})

test("configJob keeps a secret config value off the helper's command line", () => {
  const secret = Model.configJob("socksPassword", "hunter2")
  assert.deepEqual(secret, { args: ["config", "set", "socksPassword", "-"], stdin: "hunter2" })
  assert.ok(!secret.args.join(" ").includes("hunter2"))
  // Even a value the helper will refuse never lands in args.
  assert.deepEqual(Model.configJob("socksPassword", "-"), { args: ["config", "set", "socksPassword", "-"], stdin: "-" })
  assert.deepEqual(Model.configJob("socksPassword", null).stdin, "")
  // Every other key keeps its value on argv exactly as before.
  assert.deepEqual(Model.configJob("mode", "socks"), { args: ["config", "set", "mode", "socks"], stdin: null })
  assert.deepEqual(Model.configJob("socksPort", 1085), { args: ["config", "set", "socksPort", "1085"], stdin: null })
  assert.deepEqual(Model.configJob("postQuantum", false), { args: ["config", "set", "postQuantum", "false"], stdin: null })
  assert.deepEqual(Model.configJob("socksUsername", "proxyuser"), { args: ["config", "set", "socksUsername", "proxyuser"], stdin: null })
})

test("CONFIG_STDIN_KEYS matches agvpn.py's stdin-only setters and Service.setConfig goes through configJob", () => {
  const { execFileSync } = require("node:child_process")
  const fs = require("node:fs")
  const path = require("node:path")
  const env = Object.assign({}, process.env, { PYTHONDONTWRITEBYTECODE: "1" })
  for (const k of Object.keys(env)) if (k.startsWith("AEGIS_")) delete env[k]
  const script = [
    "import importlib.util, json",
    "spec = importlib.util.spec_from_file_location('agvpn', 'agvpn.py')",
    "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)",
    "print(json.dumps(sorted(k for k, (sub, kind) in m.CONFIG_SETTERS.items() if kind == 'stdin')))",
  ].join("\n")
  const keys = JSON.parse(execFileSync("python3", ["-c", script], { cwd: path.join(__dirname, ".."), env, encoding: "utf8" }))
  assert.deepEqual(Model.CONFIG_STDIN_KEYS.slice().sort(), keys)
  const src = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
  assert.match(src, /Model\.configJob\(/)
  assert.doesNotMatch(src, /enqueue\(\["config",\s*"set"/, "a config set must be built by Model.configJob")
})

test("normalizeUpdate maps fields and defaults to up to date", () => {
  assert.deepEqual(Model.normalizeUpdate({ upToDate: false, current: "1.7.12", latest: "1.7.13", checkedAt: 1700000000 }),
    { upToDate: false, current: "1.7.12", latest: "1.7.13", checkedAt: 1700000000 })
  assert.deepEqual(Model.normalizeUpdate(undefined), { upToDate: true, current: "", latest: null, checkedAt: 0 })
  assert.deepEqual(Model.normalizeUpdate({ upToDate: "yes", checkedAt: "x" }), { upToDate: true, current: "", latest: null, checkedAt: 0 })
})

test("parseAppList splits, trims, dedupes and drops invalid names; formatAppList joins", () => {
  assert.deepEqual(Model.parseAppList("firefox, qbittorrent;  chromium firefox"), ["firefox", "qbittorrent", "chromium"])
  assert.deepEqual(Model.parseAppList("ok-name bad/name a.b+c ../x"), ["ok-name", "a.b+c"])
  assert.deepEqual(Model.parseAppList(""), [])
  assert.deepEqual(Model.parseAppList(null), [])
  assert.equal(Model.formatAppList(["a", "b", "c"]), "a, b, c")
  assert.equal(Model.formatAppList([]), "")
  assert.equal(Model.formatAppList(null), "")
})

test("isDeniedApp refuses session-critical process names case-insensitively", () => {
  assert.equal(Model.isDeniedApp("bash"), true)
  assert.equal(Model.isDeniedApp("BASH"), true)
  assert.equal(Model.isDeniedApp("Hyprland"), true)
  assert.equal(Model.isDeniedApp("hyprland"), true)
  assert.equal(Model.isDeniedApp("HYPRLAND"), true)
  assert.equal(Model.isDeniedApp("quickshell"), true)
  assert.equal(Model.isDeniedApp("qs"), true)
  assert.equal(Model.isDeniedApp("adguardvpn-cli"), true)
  assert.equal(Model.isDeniedApp("systemd-logind"), true) // prefix match
  assert.equal(Model.isDeniedApp("firefox"), false)
  assert.equal(Model.isDeniedApp("systemd"), true)
})

test("parseAppList and addApp never admit a deny-listed name, even edited by hand", () => {
  assert.deepEqual(Model.parseAppList("firefox, bash, Hyprland, SUDO, qs"), ["firefox"])
  assert.deepEqual(Model.addApp(["firefox"], "bash"), ["firefox"])
  assert.deepEqual(Model.addApp(["firefox"], "Hyprland"), ["firefox"])
  assert.deepEqual(Model.addApp(["firefox"], "omarchy-shell"), ["firefox"])
})

test("tunnelLoss splits connected→down into drop vs requested disconnect", () => {
  assert.equal(Model.tunnelLoss("connected", "disconnected", false), "drop")
  assert.equal(Model.tunnelLoss("connected", "disconnected", undefined), "drop")
  assert.equal(Model.tunnelLoss("connected", "disconnected", true), "disconnect")
  assert.equal(Model.tunnelLoss("connected", "logged_out", true), "disconnect")
  assert.equal(Model.tunnelLoss("connected", "logged_out", false), "")
  assert.equal(Model.tunnelLoss("connecting", "disconnected", false), "")
  assert.equal(Model.tunnelLoss("logged_out", "logged_out", true), "")
  assert.equal(Model.tunnelLoss("connected", "connected", false), "")
  assert.equal(Model.tunnelLoss("disconnected", "disconnected", true), "")
  assert.equal(Model.tunnelLoss("unknown", "disconnected", false), "")
})

test("settleStatus judges a Disconnect before settling the toggle (the old order reported a drop)", () => {
  const ctx = { prevState: "connected", nextState: "disconnected", desired: 0, requested: false, wasConnected: false }
  // Old applySnapshot: reset desired to -1 on the disconnected status, then asked about the drop.
  const settledFirst = ctx.desired === 0 && ctx.nextState === "disconnected" ? -1 : ctx.desired
  assert.equal(Model.tunnelLoss(ctx.prevState, ctx.nextState, settledFirst === 0), "drop")
  const step = Model.settleStatus(ctx)
  assert.equal(step.loss, "disconnect")
  assert.equal(step.desired, -1)
  assert.equal(step.wasConnected, null)
})

test("settleStatus classifies drops, settles the pending toggle and leaves unrelated states alone", () => {
  const drop = Model.settleStatus({ prevState: "connected", nextState: "disconnected", desired: -1, wasConnected: true })
  assert.deepEqual(drop, { desired: -1, loss: "drop", wasConnected: null }, "a drop keeps wasConnected for reconnect-at-login")
  // Disconnect result arriving after the user already asked to connect again.
  const retoggle = Model.settleStatus({ prevState: "connected", nextState: "disconnected", desired: 1, requested: true, wasConnected: false })
  assert.deepEqual(retoggle, { desired: 1, loss: "disconnect", wasConnected: null })
  const up = Model.settleStatus({ prevState: "connecting", nextState: "connected", desired: 1, wasConnected: false })
  assert.deepEqual(up, { desired: -1, loss: "", wasConnected: true })
  const still = Model.settleStatus({ prevState: "connected", nextState: "connected", desired: -1, wasConnected: true })
  assert.deepEqual(still, { desired: -1, loss: "", wasConnected: null })
  assert.deepEqual(Model.settleStatus({ prevState: "unknown", nextState: "disconnected", desired: 7 }),
    { desired: -1, loss: "", wasConnected: null })
  assert.deepEqual(Model.settleStatus(null), { desired: -1, loss: "", wasConnected: null })
})

test("settleStatus never re-sets wasConnected while a disconnect is pending, and a requested disconnect clears it", () => {
  // Queued connect lands "connected" after the user already toggled off.
  const late = Model.settleStatus({ prevState: "disconnected", nextState: "connected", desired: 0, wasConnected: false })
  assert.deepEqual(late, { desired: 0, loss: "", wasConnected: null })
  const off = Model.settleStatus({ prevState: "connected", nextState: "disconnected", desired: 0, requested: true, wasConnected: true })
  assert.deepEqual(off, { desired: -1, loss: "disconnect", wasConnected: false })
})

test("errorProtected shields action and sudo errors from routine background outcomes", () => {
  assert.equal(Model.errorProtected("action"), true)
  assert.equal(Model.errorProtected("sudo"), true)
  assert.equal(Model.errorProtected("parse"), false)
  assert.equal(Model.errorProtected(""), false)
  assert.equal(Model.errorProtected(undefined), false)
})

test("errorResolved clears a connect error only once the snapshot is connected to that same target", () => {
  const intent = { verb: "connect", target: "Paris" }
  assert.equal(Model.errorResolved(intent, { state: "connected", location: "Paris" }), true)
  // Connected, but to somewhere else: the original "location not found" stands.
  assert.equal(Model.errorResolved(intent, { state: "connected", location: "Tokyo" }), false)
  assert.equal(Model.errorResolved(intent, { state: "connecting", location: "Paris" }), false)
  assert.equal(Model.errorResolved(intent, { state: "disconnected", location: "" }), false)
  assert.equal(Model.errorResolved({ verb: "connect", target: "" }, { state: "connected", location: "" }), false)
})

test("errorResolved compares the connect target case- and whitespace-insensitively", () => {
  const intent = { verb: "connect", target: "Paris" }
  assert.equal(Model.errorResolved(intent, { state: "connected", location: "PARIS" }), true)
  assert.equal(Model.errorResolved(intent, { state: "connected", location: "paris" }), true)
  assert.equal(Model.errorResolved(intent, { state: "connected", location: " Paris " }), true)
  assert.equal(Model.errorResolved({ verb: "connect", target: " paris " }, { state: "connected", location: "Paris" }), true)
  assert.equal(Model.errorResolved(intent, { state: "connected", location: "Paris, France" }), false)
})

test("errorResolved clears a disconnect error once the snapshot is disconnected, regardless of location", () => {
  const intent = { verb: "disconnect" }
  assert.equal(Model.errorResolved(intent, { state: "disconnected", location: "" }), true)
  assert.equal(Model.errorResolved(intent, { state: "connected", location: "Paris" }), false)
  assert.equal(Model.errorResolved(intent, { state: "connecting", location: "" }), false)
})

test("errorResolved is false without a recognised intent or snapshot", () => {
  assert.equal(Model.errorResolved(null, { state: "connected", location: "Paris" }), false)
  assert.equal(Model.errorResolved({ verb: "exclusions" }, { state: "connected", location: "Paris" }), false)
  assert.equal(Model.errorResolved({ verb: "connect", target: "Paris" }, null), false)
})

test("lossResponse: drops always alert, disconnects close apps only with killOnDisconnect", () => {
  const apps = ["firefox", "foot"]
  assert.deepEqual(Model.lossResponse("drop", { location: "Tokyo", killSwitch: true, apps }),
    { kill: apps, title: "VPN dropped", body: "Tunnel to Tokyo dropped · closed firefox, foot", urgency: "critical" })
  assert.deepEqual(Model.lossResponse("drop", { location: "Tokyo", killSwitch: false, killOnDisconnect: true, apps }),
    { kill: [], title: "VPN dropped", body: "Tunnel to Tokyo dropped", urgency: "critical" })
  assert.deepEqual(Model.lossResponse("drop", { location: "", killSwitch: true, apps: [] }),
    { kill: [], title: "VPN dropped", body: "Tunnel dropped", urgency: "critical" })
  assert.deepEqual(Model.lossResponse("disconnect", { location: "Tokyo", killSwitch: true, killOnDisconnect: true, apps }),
    { kill: apps, title: "VPN disconnected", body: "Disconnected from Tokyo · closed firefox, foot", urgency: "normal" })
  assert.equal(Model.lossResponse("disconnect", { location: "Tokyo", killSwitch: true, killOnDisconnect: false, apps }), null)
  assert.equal(Model.lossResponse("disconnect", { location: "Tokyo", killSwitch: false, killOnDisconnect: true, apps }), null)
  assert.equal(Model.lossResponse("disconnect", { location: "Tokyo", killSwitch: true, killOnDisconnect: true, apps: [] }), null)
  assert.equal(Model.lossResponse("", { killSwitch: true, killOnDisconnect: true, apps }), null)
  const arrayLike = { length: 1, 0: "firefox" }
  assert.deepEqual(Model.lossResponse("drop", { killSwitch: true, apps: arrayLike }).kill, ["firefox"])
})

test("shouldAutoConnect requires every precondition", () => {
  const base = { autoConnect: true, wasConnected: true, state: "disconnected", installed: true, loggedIn: true, attempted: false }
  assert.equal(Model.shouldAutoConnect(base), true)
  assert.equal(Model.shouldAutoConnect(Object.assign({}, base, { autoConnect: false })), false)
  assert.equal(Model.shouldAutoConnect(Object.assign({}, base, { wasConnected: false })), false)
  assert.equal(Model.shouldAutoConnect(Object.assign({}, base, { attempted: true })), false)
  assert.equal(Model.shouldAutoConnect(Object.assign({}, base, { installed: false })), false)
  assert.equal(Model.shouldAutoConnect(Object.assign({}, base, { loggedIn: false })), false)
  assert.equal(Model.shouldAutoConnect(Object.assign({}, base, { loggedIn: undefined })), true)
  assert.equal(Model.shouldAutoConnect(Object.assign({}, base, { state: "connected" })), false)
  assert.equal(Model.shouldAutoConnect(Object.assign({}, base, { state: "unknown" })), false)
  assert.equal(Model.shouldAutoConnect(null), false)
})

test("mayLocateHome only allows a lookup once the tunnel is down by choice", () => {
  const base = { locateHome: true, state: "disconnected", startupSettled: true, autoConnectPending: false,
    dropHold: false, wasConnected: false }
  assert.equal(Model.mayLocateHome(base), true)
  // The setting itself.
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { locateHome: false })), false)
  // Only while the tunnel is actually down.
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { state: "connected" })), false)
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { state: "connecting" })), false)
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { state: "logged_out" })), false)
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { state: "unknown" })), false)
  // Never before the first status has settled, even if it already reads
  // "disconnected" (the very first snapshot hasn't been judged yet).
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { startupSettled: false })), false)
  // Never while startup auto-connect is about to reconnect.
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { autoConnectPending: true })), false)
  // Held after an unexpected drop until the user acts again.
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { dropHold: true })), false)
  // A failed startup auto-connect (network not up yet at login): nothing is
  // pending any more (autoConnectPending false, dropHold false — this was
  // never a drop), the CLI already reads disconnected, but wasConnected is
  // still true from last session, so the user's standing intent is "VPN on"
  // — no lookup, even though every other guard would allow one.
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { wasConnected: true })), false)
  // An intentional disconnect clears wasConnected itself (Service.down()),
  // so once it reads false a lookup is allowed — the user chose this.
  assert.equal(Model.mayLocateHome(Object.assign({}, base, { wasConnected: false })), true)
  assert.equal(Model.mayLocateHome(null), false)
  assert.equal(Model.mayLocateHome(undefined), false)
})

test("shouldApplyHomeJob never lets a cache-only miss erase a home a real lookup already set", () => {
  const set = { lat: 1, lon: 2, city: "X", iso: "XX" }
  // The dangerous case this exists for: a cache-only answer (fromCache
  // true) with nothing on disk (incomingHome null) must not blow away a
  // home a real lookup already set.
  assert.equal(Model.shouldApplyHomeJob(set, true, null), false)
  // Nothing to protect when there is no in-memory home yet.
  assert.equal(Model.shouldApplyHomeJob(null, true, null), true)
  // A cache hit is always applied, home already set or not — it can only
  // ever repeat what a lookup itself would have written to disk.
  assert.equal(Model.shouldApplyHomeJob(set, true, { lat: 3, lon: 4, city: "Y", iso: "YY" }), true)
  assert.equal(Model.shouldApplyHomeJob(null, true, { lat: 3, lon: 4, city: "Y", iso: "YY" }), true)
  // A real lookup's own answer is always applied, null included — it is the
  // freshest information there is, unaffected by this guard.
  assert.equal(Model.shouldApplyHomeJob(set, false, null), true)
  assert.equal(Model.shouldApplyHomeJob(null, false, null), true)
})

test("updateCheckDue is true when never checked or older than the interval", () => {
  const now = 1700000000 * 1000
  assert.equal(Model.updateCheckDue(0, now), true)
  assert.equal(Model.updateCheckDue(null, now), true)
  assert.equal(Model.updateCheckDue(1700000000 - 100, now), false)
  assert.equal(Model.updateCheckDue(1700000000 - 86401, now), true)
  assert.equal(Model.updateCheckDue(1700000000 - 100, now, 60), true)
  assert.equal(Model.updateCheckDue(1700000000 - 30, now, 60), false)
})

test("protocolLabel and dnsLabel give user-facing names", () => {
  assert.equal(Model.protocolLabel("auto"), "Auto")
  assert.equal(Model.protocolLabel("http2"), "HTTP/2")
  assert.equal(Model.protocolLabel("quic"), "QUIC")
  assert.equal(Model.protocolLabel("other"), "Auto")
  assert.equal(Model.dnsLabel("default"), "AdGuard")
  assert.equal(Model.dnsLabel(""), "AdGuard")
  assert.equal(Model.dnsLabel("1.1.1.1"), "1.1.1.1")
})

test("describeDrop names the location when known", () => {
  assert.equal(Model.describeDrop("Tokyo"), "Tunnel to Tokyo dropped")
  assert.equal(Model.describeDrop(""), "Tunnel dropped")
  assert.equal(Model.describeDrop(null), "Tunnel dropped")
  assert.equal(Model.describeDisconnect(" Tokyo "), "Disconnected from Tokyo")
  assert.equal(Model.describeDisconnect(null), "Disconnected")
})

test("filterProcs ranks prefix matches before substring matches, skips chosen, caps at limit", () => {
  const procs = { length: 6, 0: "firefox", 1: "Foot", 2: "transmission-gtk", 3: "gnome-firmware", 4: "fish", 5: "foot" }
  assert.deepEqual(Model.filterProcs(procs, "f", [], 6), ["firefox", "fish", "Foot", "foot", "gnome-firmware"])
  assert.deepEqual(Model.filterProcs(procs, "fi", ["firefox"], 6), ["fish", "gnome-firmware"])
  assert.deepEqual(Model.filterProcs(procs, "f", [], 2), ["firefox", "fish"])
  assert.deepEqual(Model.filterProcs(procs, "", [], 6), [])
  assert.deepEqual(Model.filterProcs(procs, "zzz", [], 6), [])
  assert.deepEqual(Model.filterProcs(null, "f", [], 6), [])
  assert.equal(Model.filterProcs(["a1", "a2", "a3", "a4", "a5", "a6", "a7"], "a").length, 6)
})

test("addApp appends a valid name once, removeApp drops it", () => {
  assert.deepEqual(Model.addApp(["firefox"], "foot"), ["firefox", "foot"])
  assert.deepEqual(Model.addApp(["firefox"], "firefox"), ["firefox"])
  assert.deepEqual(Model.addApp(["firefox"], "bad/name"), ["firefox"])
  assert.deepEqual(Model.addApp(null, " foot "), ["foot"])
  assert.deepEqual(Model.removeApp(["firefox", "foot"], "foot"), ["firefox"])
  assert.deepEqual(Model.removeApp(["firefox"], "nope"), ["firefox"])
  const src = ["firefox"]
  Model.addApp(src, "foot")
  assert.deepEqual(src, ["firefox"], "input not mutated")
})

test("normalizePaused always yields both mode lists, cleaned", () => {
  assert.deepEqual(Model.normalizePaused(null), { general: [], selective: [] })
  assert.deepEqual(Model.normalizePaused("junk"), { general: [], selective: [] })
  assert.deepEqual(Model.normalizePaused({ general: [" A.com ", "a.com", "", "b.org"] }), { general: ["a.com", "b.org"], selective: [] })
  assert.deepEqual(Model.normalizePaused({ selective: { length: 1, 0: "X.net" }, other: ["z"] }), { general: [], selective: ["x.net"] })
})

test("normalizePaused drops a domain starting with -: it would reach adguardvpn-cli as an option, not a domain", () => {
  assert.deepEqual(Model.normalizePaused({ general: ["-x", "--help", "a.com"] }), { general: ["a.com"], selective: [] })
})

test("mergeExclusions keeps one stable alphabetical order so pausing never moves a row", () => {
  const rows = Model.mergeExclusions(["news.example.com", "anthropic.com"], ["example.org", "anthropic.com"])
  assert.deepEqual(rows, [
    { domain: "anthropic.com", paused: false },
    { domain: "example.org", paused: true },
    { domain: "news.example.com", paused: false }
  ])
  assert.deepEqual(Model.mergeExclusions([], []), [])
  assert.deepEqual(Model.mergeExclusions(["B.com", "a.com"], []), [{ domain: "a.com", paused: false }, { domain: "b.com", paused: false }], "hostnames are case-insensitive, so rows are lowercased")
  assert.deepEqual(Model.mergeExclusions(["-x", "a.com"], []), [{ domain: "a.com", paused: false }], "an option-like active domain is dropped rather than shown")
})
test("setPaused adds or removes a domain in the right mode without mutating input", () => {
  const base = { general: ["a.com"], selective: [] }
  const paused = Model.setPaused(base, "general", "B.org", true)
  assert.deepEqual(paused, { general: ["a.com", "b.org"], selective: [] })
  assert.deepEqual(base, { general: ["a.com"], selective: [] })
  assert.deepEqual(Model.setPaused(paused, "general", "a.com", false), { general: ["b.org"], selective: [] })
  assert.deepEqual(Model.setPaused(paused, "selective", "x.io", true), { general: ["a.com", "b.org"], selective: ["x.io"] })
  assert.deepEqual(Model.setPaused(paused, "weird", "x.io", true), paused)
  assert.deepEqual(Model.setPaused(null, "general", "a.com", true), { general: ["a.com"], selective: [] })
})

test("findExclusionDomain finds the CLI's stored spelling case-insensitively", () => {
  const domains = ["Example.com", "b.org", " C.io "]
  assert.equal(Model.findExclusionDomain(domains, "example.com"), "Example.com")
  assert.equal(Model.findExclusionDomain(domains, "EXAMPLE.COM"), "Example.com")
  assert.equal(Model.findExclusionDomain(domains, "b.org"), "b.org")
  assert.equal(Model.findExclusionDomain(domains, "c.io"), " C.io ", "matches despite the CLI's own stray whitespace")
  assert.equal(Model.findExclusionDomain(domains, "nope.com"), null)
  assert.equal(Model.findExclusionDomain(domains, ""), null)
  assert.equal(Model.findExclusionDomain(null, "example.com"), null)
})

test("chooseKillSwitchName: Tab always takes the highlighted suggestion; Enter takes exactly what was typed unless navigated", () => {
  const suggestions = ["steamwebhelper", "steam-native"]
  // The bug: typing "steam" while steamwebhelper is running always added
  // the top suggestion, so "steam" itself could never be added.
  assert.equal(Model.chooseKillSwitchName("steam", suggestions, 0, false, "enter"), "steam")
  assert.equal(Model.chooseKillSwitchName("steam", suggestions, 0, false, "tab"), "steamwebhelper")
  // Enter after arrowing (Up/Down, or hovering) takes the highlighted one.
  assert.equal(Model.chooseKillSwitchName("steam", suggestions, 1, true, "enter"), "steam-native")
  assert.equal(Model.chooseKillSwitchName("steam", suggestions, 1, true, "tab"), "steam-native")
  // No suggestions at all: both keys fall back to the typed text.
  assert.equal(Model.chooseKillSwitchName("firefox", [], 0, false, "enter"), "firefox")
  assert.equal(Model.chooseKillSwitchName("firefox", [], 0, false, "tab"), "firefox")
  // Typed text exactly matching the top suggestion behaves the same either way.
  assert.equal(Model.chooseKillSwitchName("steamwebhelper", suggestions, 0, false, "enter"), "steamwebhelper")
  // An out-of-range highlight index is clamped.
  assert.equal(Model.chooseKillSwitchName("steam", suggestions, 9, true, "tab"), "steam-native")
  assert.equal(Model.chooseKillSwitchName("  steam  ", [], 0, false, "enter"), "steam", "typed text is trimmed")
})

test("isDeniedApp covers the session/security-critical additions, case-insensitively", () => {
  const names = ["hyprlock", "HYPRLOCK", "hypridle", "uwsm", "xwayland", "Xwayland",
    "xdg-desktop-portal-hyprland", "polkit", "polkitd", "hyprpolkitagent",
    "gnome-keyring-daemon", "ssh-agent", "gpg-agent", "login", "agetty",
    "swayosd-server", "mako", "walker", "elephant"]
  for (const name of names) assert.equal(Model.isDeniedApp(name), true, name)
  // ps/pkill only ever see a comm truncated to 15 bytes, so the truncated
  // form of a longer denied name must be denied too.
  assert.equal(Model.isDeniedApp("gnome-keyring-d"), true, "truncated comm of a denied name")
  assert.equal(Model.isDeniedApp("gnome-keyring"), false, "a shorter, unrelated name must not be denied")
})

test("PROCS_DENY / PROCS_DENY_PREFIXES stay in sync with agvpn.py's _is_denied", () => {
  const { execFileSync } = require("node:child_process")
  const path = require("node:path")
  const env = Object.assign({}, process.env, { PYTHONDONTWRITEBYTECODE: "1" })
  for (const k of Object.keys(env)) if (k.startsWith("AEGIS_")) delete env[k]
  const script = [
    "import importlib.util, json",
    "spec = importlib.util.spec_from_file_location('agvpn', 'agvpn.py')",
    "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)",
    "print(json.dumps({'deny': sorted(m.PROCS_DENY_LOWER), 'prefixes': sorted(m.PROCS_DENY_PREFIXES)}))",
  ].join("\n")
  const info = JSON.parse(execFileSync("python3", ["-c", script], { cwd: path.join(__dirname, ".."), env, encoding: "utf8" }))
  assert.deepEqual(Model.PROCS_DENY.map(n => n.toLowerCase()).sort(), info.deny)
  assert.deepEqual(Model.PROCS_DENY_PREFIXES.slice().sort(), info.prefixes)
})

test("normalizeSnapshot keeps the tunnel mode and SOCKS listen address", () => {
  const s = Model.normalizeSnapshot({ ok: true, state: "connected", location: "Astana", iso: "KZ", mode: "socks", listen: "127.0.0.1:1080", iface: null })
  assert.equal(s.mode, "socks")
  assert.equal(s.listen, "127.0.0.1:1080")
  const t = Model.normalizeSnapshot({ ok: true, state: "connected", location: "Milan", iso: "IT", mode: "tun", iface: "tun0" })
  assert.equal(t.mode, "tun")
  assert.equal(t.listen, null)
  assert.equal(Model.normalizeSnapshot(null).mode, "tun")
})

test("heroMeta names the SOCKS proxy when the tunnel is a local proxy", () => {
  const lookup = iso => ({ KZ: "Kazakhstan" })[iso] || ""
  const snap = { state: "connected", iso: "KZ", endpoint: { pingMs: 249 }, sinceEpoch: 0, mode: "socks", listen: "127.0.0.1:1080" }
  assert.equal(Model.heroMeta(snap, Date.now(), lookup), "Kazakhstan · 249 ms · SOCKS 127.0.0.1:1080")
  const tun = { state: "connected", iso: "KZ", endpoint: { pingMs: 249 }, sinceEpoch: 0, mode: "tun", listen: null }
  assert.equal(Model.heroMeta(tun, Date.now(), lookup), "Kazakhstan · 249 ms")
})

test("HELPER_BUDGET_SEC is an exact copy of agvpn.py's budgets and the watchdog outlasts each one", () => {
  const { execFileSync } = require("node:child_process")
  const path = require("node:path")
  const env = Object.assign({}, process.env, { PYTHONDONTWRITEBYTECODE: "1" })
  for (const k of Object.keys(env)) if (k.startsWith("AEGIS_")) delete env[k]
  const script = [
    "import importlib.util, json",
    "spec = importlib.util.spec_from_file_location('agvpn', 'agvpn.py')",
    "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)",
    "print(json.dumps({'budgets': m.verb_budgets(), 'stopGrace': m.STOP_GRACE}))",
  ].join("\n")
  const info = JSON.parse(execFileSync("python3", ["-c", script], { cwd: path.join(__dirname, ".."), env, encoding: "utf8" }))
  assert.deepEqual(Model.HELPER_BUDGET_SEC, info.budgets)
  for (const verb of Object.keys(info.budgets))
    assert.ok(Model.watchdogMs(verb) >= info.budgets[verb] * 1000 + 2000, verb)
  assert.ok(Model.WATCHDOG_KILL_MS >= info.stopGrace * 1000 + 2000)
})

test("every helper verb Service.qml enqueues has a watchdog budget; unknown verbs get the longest", () => {
  const fs = require("node:fs")
  const path = require("node:path")
  const src = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
  const verbs = [...src.matchAll(/enqueue\(\["([a-z-]+)"/g)].map(m => m[1])
  assert.ok(verbs.length >= 10)
  for (const verb of verbs) assert.ok(Object.prototype.hasOwnProperty.call(Model.HELPER_BUDGET_SEC, verb), verb)
  const longest = Math.max(...Object.values(Model.HELPER_BUDGET_SEC)) * 1000 + Model.WATCHDOG_SLACK_MS
  assert.equal(Model.watchdogMs("frobnicate"), longest)
  assert.equal(Model.watchdogMs(undefined), longest)
  assert.equal(Model.watchdogMs("connect"), 84000 + Model.WATCHDOG_SLACK_MS)
  assert.equal(Model.watchdogMs("update-check"), 36000 + Model.WATCHDOG_SLACK_MS)
})

// --- tunnel.log trigger --------------------------------------------------------

const tunnelFixture = name => require("node:fs").readFileSync(require("node:path").join(__dirname, "fixtures", name), "utf8")

test("lossBase keeps connected through a connecting status, so a drop mid-recovery is still a drop", () => {
  assert.equal(Model.lossBase("connected", "connecting"), "connected")
  assert.equal(Model.lossBase("disconnected", "connecting"), "disconnected")
  assert.equal(Model.lossBase("connected", "disconnected"), "disconnected")
  assert.equal(Model.lossBase("connecting", "connected"), "connected")
  assert.equal(Model.lossBase("", "connecting"), "unknown")
  assert.equal(Model.lossBase(undefined, "connecting"), "unknown")
  // Replays Service: each status judged from the base, then the base moves.
  function replay(states, desired) {
    let base = "unknown"
    const losses = []
    for (const s of states) {
      losses.push(Model.settleStatus({ prevState: base, nextState: s, desired: desired === undefined ? -1 : desired, wasConnected: true }).loss)
      base = Model.lossBase(base, s)
    }
    return losses
  }
  assert.deepEqual(replay(["connected", "connecting", "disconnected"]), ["", "", "drop"])
  // Judged from the raw previous status (the old wiring), that drop was lost.
  assert.equal(Model.settleStatus({ prevState: "connecting", nextState: "disconnected", desired: -1, wasConnected: true }).loss, "")
  assert.deepEqual(replay(["connected", "connecting", "connecting", "connected"]), ["", "", "", ""])
  assert.deepEqual(replay(["disconnected", "connecting", "disconnected"]), ["", "", ""])
  assert.deepEqual(replay(["connected", "connecting", "disconnected"], 0), ["", "", "disconnect"])
  assert.equal(Model.tunnelLoss(Model.lossBase("connected", "connecting"), "logged_out", true), "disconnect")
})

test("tunnelLogPath follows agvpn.py data_dir()", () => {
  assert.equal(Model.tunnelLogPath({ HOME: "/home/u" }), "/home/u/.local/share/adguardvpn-cli/tunnel.log")
  assert.equal(Model.tunnelLogPath({ HOME: "/home/u", XDG_DATA_HOME: "/data/" }), "/data/adguardvpn-cli/tunnel.log")
  assert.equal(Model.tunnelLogPath({ HOME: "/home/u", XDG_DATA_HOME: "", AEGIS_DATA_DIR: "/tmp/fake" }), "/tmp/fake/tunnel.log")
  assert.equal(Model.tunnelLogPath({ HOME: "/home/u", XDG_DATA_HOME: null }), "/home/u/.local/share/adguardvpn-cli/tunnel.log")
  assert.equal(Model.tunnelLogPath({ HOME: undefined }), "")
  assert.equal(Model.tunnelLogPath(null), "")
})

test("tunnelLogStates reads complete raise_state lines only", () => {
  assert.deepEqual(Model.tunnelLogStates(tunnelFixture("tunnel_tail.txt")).map(s => s.state),
    ["connecting", "connected", "disconnected", "connecting", "connected", "disconnected", "connecting", "connected", "disconnected"])
  const recovery = Model.tunnelLogStates(tunnelFixture("tunnel_recovery.txt"))
  assert.deepEqual(recovery.map(s => s.state), ["waiting_recovery", "recovering", "connected"])
  assert.equal(recovery[2].line, "11.09.2026 09:04:10.508739 INFO  [3040] VPNCORE raise_state: [1] VPN_SS_CONNECTED")
  const full = "10.09.2026 23:15:41.098252 INFO  [16951] VPNCORE raise_state: [1] VPN_SS_DISCONNECTED"
  // `tail -c` cut into the first line; the daemon is mid-way through the last.
  assert.deepEqual(Model.tunnelLogStates(full.slice(9) + "\n" + full + "\n" + full.slice(0, -6)).map(s => s.state), ["disconnected"])
  assert.deepEqual(Model.tunnelLogStates(full), [])
  assert.deepEqual(Model.tunnelLogStates(full + "\r\n").map(s => s.state), ["disconnected"])
  assert.deepEqual(Model.tunnelLogStates("VPN_SS_CONNECTED\nnoise VPNCORE raise_state: [1] VPN_SS_CONNECTED\n"), [])
  assert.deepEqual(Model.tunnelLogStates(null), [])
})

test("scanTunnelLog: priming, new lines since the last look, and a lost position", () => {
  const lines = tunnelFixture("tunnel_tail.txt").split("\n")
  const upTo = n => lines.slice(0, n).join("\n") + "\n"
  const prime = Model.scanTunnelLog(upTo(9), null)
  assert.deepEqual(prime, { states: [], latest: "connected", seen: lines[8], lost: false, primed: true })
  const next = Model.scanTunnelLog(upTo(21), prime.seen)
  assert.deepEqual(next, { states: ["disconnected", "connecting", "connected"], latest: "connected", seen: lines[20], lost: false, primed: false })
  assert.deepEqual(Model.scanTunnelLog(upTo(23), next.seen).states, [])
  // The last line scrolled out (replaced, truncated, or a burst bigger than the window).
  const lost = Model.scanTunnelLog(lines.slice(22, 36).join("\n") + "\n", next.seen)
  assert.equal(lost.lost, true)
  assert.deepEqual(lost.states, ["disconnected", "connecting", "connected", "disconnected"])
  assert.equal(lost.latest, "disconnected")
  const gone = Model.scanTunnelLog("", next.seen)
  assert.deepEqual(gone, { states: [], latest: "", seen: "", lost: true, primed: false })
  // "": the last look had no state line in view, so every one now is new.
  assert.deepEqual(Model.scanTunnelLog(upTo(12), "").states, ["connecting", "connected", "disconnected"])
  assert.equal(Model.scanTunnelLog(upTo(12), "").lost, false)
})

test("tunnelLogAction confirms downs, refreshes on ups, and ignores a tunnel that wasn't up", () => {
  const up = "connected"
  assert.equal(Model.tunnelLogAction({ states: [], latest: "connected", primed: true }, up), "none")
  assert.equal(Model.tunnelLogAction({ states: [], latest: "disconnected", primed: true }, up), "confirm")
  assert.equal(Model.tunnelLogAction({ states: [], latest: "", primed: true }, up), "none")
  assert.equal(Model.tunnelLogAction({ states: [], latest: "disconnected" }, up), "none")
  assert.equal(Model.tunnelLogAction({ states: ["disconnected"], latest: "disconnected" }, up), "confirm")
  assert.equal(Model.tunnelLogAction({ states: ["waiting_recovery"], latest: "waiting_recovery" }, up), "confirm")
  assert.equal(Model.tunnelLogAction({ states: ["disconnected", "connecting"], latest: "connecting" }, up), "confirm")
  assert.equal(Model.tunnelLogAction({ states: ["disconnected", "connecting", "connected"], latest: "connected" }, up), "refresh")
  assert.equal(Model.tunnelLogAction({ states: [], latest: "", lost: true }, up), "refresh")
  assert.equal(Model.tunnelLogAction({ states: ["connected"], latest: "connected", lost: true }, up), "refresh")
  assert.equal(Model.tunnelLogAction({ states: ["disconnected"], latest: "disconnected", lost: true }, up), "confirm")
  for (const base of ["disconnected", "logged_out", "unknown", "connecting", "", undefined])
    assert.equal(Model.tunnelLogAction({ states: ["disconnected"], latest: "disconnected" }, base), "none")
  assert.equal(Model.tunnelLogAction(null, up), "none")
})

test("confirmDrop only asks for a snapshot while the log says down and the tunnel is still thought up", () => {
  assert.equal(Model.confirmDrop("disconnected", "connected"), true)
  assert.equal(Model.confirmDrop("waiting_recovery", "connected"), true)
  assert.equal(Model.confirmDrop("", "connected"), true)
  assert.equal(Model.confirmDrop("connected", "connected"), false)
  assert.equal(Model.confirmDrop("disconnected", "disconnected"), false)
  assert.equal(Model.confirmDrop("disconnected", "logged_out"), false)
})

// Replays Service's trigger path over a timeline of log chunks: each look is
// scanned against the last, a "confirm" starts the (single) confirm timer, and
// when it fires confirmDrop decides with the newest state seen by then.
function replayLog(chunks, base) {
  let seen = null
  let latest = ""
  let confirmPending = false
  const actions = []
  for (const text of chunks) {
    const scan = Model.scanTunnelLog(text, seen)
    seen = scan.seen
    if (scan.latest !== "") latest = scan.latest
    const action = Model.tunnelLogAction(scan, base)
    actions.push(action)
    if (action === "confirm") confirmPending = true
  }
  return { actions, urgentSnapshot: confirmPending && Model.confirmDrop(latest, base) }
}

test("a location switch and a network recovery never reach the urgent snapshot; a real drop does", () => {
  const tail = tunnelFixture("tunnel_tail.txt").split("\n")
  const upTo = n => tail.slice(0, n).join("\n") + "\n"
  // Switch: looks land after DISCONNECTED (line 12), CONNECTING (19), CONNECTED (21).
  const sw = replayLog([upTo(9), upTo(12), upTo(19), upTo(21)], "connected")
  assert.deepEqual(sw.actions, ["none", "confirm", "confirm", "refresh"])
  assert.equal(sw.urgentSnapshot, false)
  // The real recovery episode, one look per state line, all within the confirm wait.
  const rec = tunnelFixture("tunnel_recovery.txt").split("\n")
  const recUpTo = n => tail.slice(0, 9).concat(rec.slice(0, n)).join("\n") + "\n"
  const recovery = replayLog([recUpTo(0), recUpTo(2), recUpTo(6), recUpTo(9)], "connected")
  assert.deepEqual(recovery.actions, ["none", "confirm", "confirm", "refresh"])
  assert.equal(recovery.urgentSnapshot, false)
  const stamp = line => { const m = /^(\d\d)\.(\d\d)\.(\d{4}) (\d\d):(\d\d):(\d\d\.\d+)/.exec(line); return Date.UTC(+m[3], +m[2] - 1, +m[1], +m[4], +m[5]) + Number(m[6]) * 1000 }
  assert.ok(Model.TUNNEL_CONFIRM_MS > stamp(rec[8]) - stamp(rec[1]) + Model.TUNNEL_SCAN_DELAY_MS, "confirm wait outlasts the recovery")
  assert.ok(Model.TUNNEL_CONFIRM_MS > stamp(tail[20]) - stamp(tail[11]) + Model.TUNNEL_SCAN_DELAY_MS, "confirm wait outlasts the switch")
  // A drop: DISCONNECTED and nothing after it.
  const drop = replayLog([upTo(9), upTo(16)], "connected")
  assert.deepEqual(drop.actions, ["none", "confirm"])
  assert.equal(drop.urgentSnapshot, true)
})

test("queueFront puts one snapshot first without reordering anything else", () => {
  const q = [{ verb: "locations" }, { verb: "connect", args: ["connect", "Tokyo"] }, { verb: "disconnect" }, { verb: "snapshot" }, { verb: "account" }]
  const job = { verb: "snapshot", args: ["snapshot"] }
  const moved = Model.queueFront(q, job)
  assert.deepEqual(moved.map(j => j.verb), ["snapshot", "locations", "connect", "disconnect", "account"])
  assert.equal(moved[0], q[3])
  assert.equal(q.length, 5)
  const inserted = Model.queueFront(q.filter(j => j.verb !== "snapshot"), job)
  assert.deepEqual(inserted.map(j => j.verb), ["snapshot", "locations", "connect", "disconnect", "account"])
  assert.equal(inserted[0], job)
  assert.deepEqual(Model.queueFront([], job), [job])
  assert.deepEqual(Model.queueFront(null, job), [job])
  const write = { verb: "config", mutate: true }
  assert.deepEqual(Model.queueFront([write], { verb: "config" }), [{ verb: "config" }, write])
})

test("sameLocations compares every rendered field", () => {
  const list = () => [loc("US", "United States", "New York", 21), loc("JP", "Japan", "Tokyo", 140)]
  assert.equal(Model.sameLocations(list(), list()), true)
  assert.equal(Model.sameLocations([], []), true)
  assert.equal(Model.sameLocations(null, []), true)
  assert.equal(Model.sameLocations(list(), list().slice(1)), false)
  // Order is part of it: the list is sorted by ping and rendered in order.
  assert.equal(Model.sameLocations(list(), list().reverse()), false)
  for (const [field, value] of [["iso", "GB"], ["country", "USA"], ["city", "Newark"],
    ["cliName", "new-york"], ["pingMs", 22], ["pingMs", null], ["virtual", true],
    ["lat", 40.7], ["lon", -74], ["favorite", true]]) {
    const changed = list()
    changed[0] = Object.assign({}, changed[0], { [field]: value })
    assert.equal(Model.sameLocations(list(), changed), false, field + " = " + value)
  }
  // normalizeLocations output has no `favorite` on either side.
  const norm = Model.normalizeLocations({ ok: true, locations: [{ iso: "us", city: "New York", pingMs: 21 }] })
  assert.equal(Model.sameLocations(norm, Model.normalizeLocations({ ok: true,
    locations: [{ iso: "us", city: "New York", pingMs: 21 }] })), true)
  // Array-likes from Qt compare like arrays.
  assert.equal(Model.sameLocations({ length: 1, 0: list()[0] }, [list()[0]]), true)
})

test("sameProcs, sameAccount, sameConfig and sameUpdate compare field by field", () => {
  assert.equal(Model.sameProcs(["firefox", "foot"], ["firefox", "foot"]), true)
  assert.equal(Model.sameProcs([], []), true)
  assert.equal(Model.sameProcs(null, []), true)
  assert.equal(Model.sameProcs(["firefox", "foot"], ["foot", "firefox"]), false)
  assert.equal(Model.sameProcs(["firefox"], ["firefox", "foot"]), false)
  assert.equal(Model.sameProcs(["firefox"], ["firefo"]), false)
  assert.equal(Model.sameProcs({ length: 1, 0: "foot" }, ["foot"]), true)

  const acct = { loggedIn: true, email: "a@b.c", plan: "Premium", devices: 3, validUntil: "2027-01-01" }
  assert.equal(Model.sameAccount(acct, Object.assign({}, acct)), true)
  assert.equal(Model.sameAccount(Model.loggedOutAccount(), Model.loggedOutAccount()), true)
  assert.equal(Model.sameAccount(acct, Model.loggedOutAccount()), false)
  for (const field of ["loggedIn", "email", "plan", "devices", "validUntil"]) {
    assert.equal(Model.sameAccount(acct, Object.assign({}, acct, { [field]: "x" })), false, field)
  }
  assert.equal(Model.sameAccount(acct, Object.assign({}, acct, { devices: null })), false)

  const cfg = Model.normalizeConfig({ mode: "socks", socksHost: "127.0.0.1", socksPort: 1080,
    socksUsername: "u", dns: "1.1.1.1", changeSystemDns: true, protocol: "quic", postQuantum: false, showHints: false })
  assert.equal(Model.sameConfig(cfg, Object.assign({}, cfg)), true)
  assert.equal(Model.sameConfig(Model.normalizeConfig(null), Model.normalizeConfig(null)), true)
  for (const [field, value] of [["mode", "tun"], ["socksHost", "0.0.0.0"], ["socksPort", 9050],
    ["socksUsername", "v"], ["dns", "default"], ["changeSystemDns", false], ["protocol", "auto"],
    ["postQuantum", true], ["showHints", true]]) {
    assert.equal(Model.sameConfig(cfg, Object.assign({}, cfg, { [field]: value })), false, field)
  }

  const up = { upToDate: false, current: "2.5.1", latest: "2.6.0", checkedAt: 1000 }
  assert.equal(Model.sameUpdate(up, Object.assign({}, up)), true)
  // checkedAt moves on every check; only "has a check ever succeeded" is read.
  assert.equal(Model.sameUpdate(up, Object.assign({}, up, { checkedAt: 999999 })), true)
  assert.equal(Model.sameUpdate(up, Object.assign({}, up, { checkedAt: 0 })), false)
  for (const [field, value] of [["upToDate", true], ["current", "2.5.2"], ["latest", null], ["latest", "2.7.0"]]) {
    assert.equal(Model.sameUpdate(up, Object.assign({}, up, { [field]: value })), false, field)
  }
  assert.equal(Model.sameUpdate(Model.normalizeUpdate(null), Model.normalizeUpdate(null)), true)
})

test("Service.qml assigns the arrays and objects only when they actually changed", () => {
  const src = require("node:fs").readFileSync(require("node:path").join(__dirname, "..", "Service.qml"), "utf8")
  assert.match(src, /if \(!Model\.sameLocations\(locations, list\)\) locations = list/)
  assert.match(src, /if \(!Model\.sameProcs\(procs, list\)\) procs = list/)
  assert.match(src, /if \(!Model\.sameAccount\(account, nextAccount\)\) account = nextAccount/)
  assert.match(src, /if \(!Model\.sameConfig\(config, nextConfig\)\) config = nextConfig/)
  assert.match(src, /if \(!Model\.sameUpdate\(update, info\)\) update = info/)
  assert.match(src, /snap\.state !== "connected" && \(rates\.down !== 0 \|\| rates\.up !== 0\)/)
  // No normalize result is assigned to those five properties unguarded any
  // more. (account = Model.loggedOutAccount() stays: it is a state change,
  // not a re-read of the same answer.)
  assert.doesNotMatch(src, /\n\s*(locations|procs|account|config|update) = Model\.(normalize|toList)/)
})

test("procsFresh reuses a process list for ten seconds and always fetches the first one", () => {
  const now = 1_700_000_000_000
  const ttl = Model.PROCS_TTL_MS
  assert.equal(ttl, 10000)
  assert.equal(Model.procsFresh(0, now, ttl), false)
  assert.equal(Model.procsFresh(null, now, ttl), false)
  assert.equal(Model.procsFresh(now - 1, now, ttl), true)
  assert.equal(Model.procsFresh(now - (ttl - 1), now, ttl), true)
  assert.equal(Model.procsFresh(now - ttl, now, ttl), false)
  assert.equal(Model.procsFresh(now - (ttl + 1), now, ttl), false)
  assert.equal(Model.procsFresh(now + 5000, now, ttl), false)
  assert.equal(Model.procsFresh(now - 1, now), true)
  assert.equal(Model.procsFresh(now - (ttl + 1), now), false)
})

test("Service.qml runs the lock-free verbs off the CLI queue without reordering home.json", () => {
  const src = require("node:fs").readFileSync(require("node:path").join(__dirname, "..", "Service.qml"), "utf8")
  // The three verbs agvpn.py answers without ever calling run_cli.
  assert.match(src, /sideEnqueue\(\["procs"\], "procs", false\)/)
  assert.match(src, /sideEnqueue\(\["home", "cached"\], "homeCache", false\)/)
  assert.match(src, /sideEnqueue\(\["home", "forget"\], "home", true\)/)
  // ...and nothing else: every CLI-backed verb keeps the serialized queue.
  const side = src.match(/sideEnqueue\(\[[^\]]*\]/g) || []
  assert.equal(side.length, 3)
  assert.equal(new Set(side).size, 3)
  assert.doesNotMatch(src, /sideEnqueue\(\["(snapshot|locations|account|connect|disconnect|logout|config|exclusions|update-check)"/)
  // The TTL gate sits in front of the procs job.
  assert.match(src, /if \(Model\.procsFresh\(_procsAt, Date\.now\(\), Model\.PROCS_TTL_MS\)\) return/)
  assert.match(src, /_procsAt = Date\.now\(\)/)
  // A home job on the side channel still orders against the `home` lookup,
  // which writes the same file from the CLI-serialized queue.
  assert.match(src, /next\.verb !== "procs" && \(\(jobProcess\.running && jobProcess\.verb === "home"\) \|\| queued\("home"\)\)/)
  assert.match(src, /root\.pump\(\)\n\s*\/\/[\s\S]*?\n\s*root\.sidePump\(\)/)
  // The write still reports its failures; the reads still stay quiet.
  assert.match(src, /else if \(mutate\) root\.noteError\(/)
  // Turning locateHome off still forgets the cached location on the spot.
  const setter = /function setLocateHome\(on\) \{[\s\S]*?\n  \}/.exec(src)
  assert.ok(setter)
  assert.match(setter[0], /home = null/)
  assert.match(setter[0], /homeStale = true/)
  assert.match(setter[0], /sideEnqueue\(\["home", "forget"\], "home", true\)/)
})

test("logScanDue rations the rearm's tail read without ever blocking the first one", () => {
  const now = 1_700_000_000_000
  const ttl = Model.LOG_SCAN_TTL_MS
  assert.equal(ttl, 5 * 60 * 1000)
  // Nothing looked yet since the watch armed: always look.
  assert.equal(Model.logScanDue(0, now, ttl), true)
  assert.equal(Model.logScanDue(null, now, ttl), true)
  assert.equal(Model.logScanDue(now - 1000, now, ttl), false)
  assert.equal(Model.logScanDue(now - (ttl - 1), now, ttl), false)
  assert.equal(Model.logScanDue(now - ttl, now, ttl), true)
  assert.equal(Model.logScanDue(now - (ttl + 1), now, ttl), true)
  // A clock that moved forward past the stamp looks rather than waits it out.
  assert.equal(Model.logScanDue(now + 60_000, now, ttl), true)
  assert.equal(Model.logScanDue(now - 1000, now), false)
  assert.equal(Model.logScanDue(now - (ttl + 1), now), true)
})

test("Service.qml rearms the tunnel.log watch every time but rations the tail read", () => {
  const src = require("node:fs").readFileSync(require("node:path").join(__dirname, "..", "Service.qml"), "utf8")
  const rearm = /function rearmTunnelLog\(\) \{[\s\S]*?\n  \}/.exec(src)
  assert.ok(rearm, "rearmTunnelLog present")
  // The pulse that rebuilds the FileView watch is unconditional.
  assert.match(rearm[0], /_logRearming = true\n\s*_logRearming = false/)
  assert.match(rearm[0], /if \(Model\.logScanDue\(_logScanAt, Date\.now\(\), Model\.LOG_SCAN_TTL_MS\)\) scheduleLogScan\(\)/)
  // The FileView's own trigger still goes straight to scheduleLogScan.
  assert.match(src, /onFileChanged: root\.scheduleLogScan\(\)/)
  assert.match(src, /if \(watchingTunnelLog\) \{ scheduleLogScan\(\); return \}/)
  // Every scan, whoever asked for it, stamps the TTL.
  assert.match(src, /_logScanAt = Date\.now\(\)\n\s*tunnelLogTail\.output = ""/)
  // The tail timings the review left alone.
  assert.equal(Model.TUNNEL_SCAN_DELAY_MS, 400)
  assert.equal(Model.TUNNEL_CONFIRM_MS, 3000)
  assert.equal(Model.TUNNEL_TAIL_BYTES, 65536)
})

test("pollIntervalMs slows the closed-panel poll only where the tunnel.log watch covers it", () => {
  const ctx = extra => Object.assign({ intervalSec: 30, panelOpen: false, connected: true,
    watchingTunnelLog: true, barMode: "icon" }, extra)
  // Open panel: exactly the configured cadence, whatever else is true.
  assert.equal(Model.pollIntervalMs(ctx({ panelOpen: true })), 30000)
  assert.equal(Model.pollIntervalMs(ctx({ panelOpen: true, connected: false })), 30000)
  // Connected, closed, watch armed: the slow fallback cadence.
  assert.equal(Model.pollIntervalMs(ctx()), Model.POLL_SLOW_MIN_MS)
  assert.equal(Model.POLL_SLOW_MIN_MS, 180000)
  // Disconnected keeps the old closed cadence — polling is the only way an
  // external connect is ever noticed.
  assert.equal(Model.pollIntervalMs(ctx({ connected: false })), 60000)
  // So does a watch that could not be armed (no log path, not installed).
  assert.equal(Model.pollIntervalMs(ctx({ watchingTunnelLog: false })), 60000)
  // ...and "rate" mode, which keeps live counters on the bar while closed.
  assert.equal(Model.pollIntervalMs(ctx({ barMode: "rate" })), 60000)
  assert.equal(Model.pollIntervalMs(ctx({ barMode: "iso" })), Model.POLL_SLOW_MIN_MS)
  // A configured interval whose doubled value already exceeds the floor is
  // never sped up by it.
  assert.equal(Model.pollIntervalMs(ctx({ intervalSec: 300 })), 600000)
  assert.equal(Model.pollIntervalMs(ctx({ intervalSec: 300, connected: false })), 600000)
  // Junk falls back to the 30 s default rather than to zero.
  assert.equal(Model.pollIntervalMs({ panelOpen: true }), 30000)
  assert.equal(Model.pollIntervalMs(null), 60000)
})

test("loginPollIntervalMs checks fast while the user is logging in, then backs off", () => {
  assert.equal(Model.LOGIN_POLL_FAST_MS, 3000)
  assert.equal(Model.LOGIN_POLL_SLOW_MS, 10000)
  assert.equal(Model.LOGIN_POLL_FAST_TICKS, 10)
  assert.equal(Model.LOGIN_POLL_MAX_TICKS, 40)
  for (let t = 0; t < Model.LOGIN_POLL_FAST_TICKS; t++) assert.equal(Model.loginPollIntervalMs(t), 3000, "tick " + t)
  for (const t of [10, 11, 25, 39]) assert.equal(Model.loginPollIntervalMs(t), 10000, "tick " + t)
  assert.equal(Model.loginPollIntervalMs(undefined), 3000)
  assert.equal(Model.loginPollIntervalMs("nope"), 3000)
  // The whole poll: 40 calls over ~5.5 minutes, where it used to be 100
  // over 5, and it still covers at least as long a login.
  let total = 0
  for (let t = 0; t < Model.LOGIN_POLL_MAX_TICKS; t++) total += Model.loginPollIntervalMs(t)
  assert.equal(total, 10 * 3000 + 30 * 10000)
  assert.ok(total >= 100 * 3000 / 2, "still waits minutes, not seconds")
  assert.ok(Model.LOGIN_POLL_MAX_TICKS < 100, "fewer license calls than before")
})

test("pollIntervalMs stops hammering a CLI that isn't installed", () => {
  assert.equal(Model.POLL_MISSING_MS, 600000)
  const ctx = extra => Object.assign({ intervalSec: 30, panelOpen: true, connected: false,
    watchingTunnelLog: false, barMode: "icon", installed: false }, extra)
  // installed: false wins over every other input, panel open included.
  assert.equal(Model.pollIntervalMs(ctx()), 600000)
  assert.equal(Model.pollIntervalMs(ctx({ panelOpen: false })), 600000)
  assert.equal(Model.pollIntervalMs(ctx({ barMode: "rate" })), 600000)
  // Only an explicit false, so an unset key keeps the normal cadence.
  assert.equal(Model.pollIntervalMs(ctx({ installed: true })), 30000)
  assert.equal(Model.pollIntervalMs(ctx({ installed: undefined })), 30000)
})

test("Service.qml gates the situational timers on what they are waiting for", () => {
  const src = require("node:fs").readFileSync(require("node:path").join(__dirname, "..", "Service.qml"), "utf8")
  const timer = id => {
    const at = src.indexOf("id: " + id)
    assert.notEqual(at, -1, id)
    return src.slice(src.lastIndexOf("Timer {", at), src.indexOf("\n  }", at))
  }
  assert.match(timer("loginPoll"), /interval: Model\.loginPollIntervalMs\(ticks\)/)
  assert.match(timer("loginPoll"), /ticks >= Model\.LOGIN_POLL_MAX_TICKS/)
  // The ramp is a shell-startup catch-up; a missing CLI ends it.
  assert.match(timer("startupRamp"), /running: root\.installed/)
  assert.match(timer("rateTimer"), /interval: root\.panelOpen \? 2000 : 5000/)
  assert.match(timer("refreshTimer"), /installed: root\.installed/)
  // Closing the panel while still logged out ends the login poll.
  assert.match(src, /if \(loginPoll\.running\) loginPoll\.stop\(\)/)
  assert.match(src, /onPanelOpenChanged: \{\n\s*if \(panelOpen\) \{ refreshAll\(\); return \}/)
})

test("queueAppend folds repeated connects into the last one and leaves everything else alone", () => {
  const tokyo = { verb: "connect", args: ["connect", "Tokyo"] }
  const paris = { verb: "connect", args: ["connect", "Paris"] }
  const oslo = { verb: "connect", args: ["connect", "Oslo"] }
  // Three clicks in a row queue one connect: the last one.
  let q = Model.queueAppend(Model.queueAppend(Model.queueAppend([], tokyo), paris), oslo)
  assert.deepEqual(q, [oslo])
  // Not the head — only the tail. A connect already running isn't in the
  // queue at all, so the first entry here is a job that is still waiting.
  q = Model.queueAppend([tokyo, { verb: "snapshot" }], paris)
  assert.deepEqual(q.map(j => j.verb), ["connect", "snapshot", "connect"])
  assert.equal(q[0], tokyo)
  assert.equal(q[2], paris)
  // A disconnect between two connects means both were meant; nothing folds.
  q = Model.queueAppend(Model.queueAppend(Model.queueAppend([], tokyo), { verb: "disconnect" }), paris)
  assert.deepEqual(q.map(j => j.verb), ["connect", "disconnect", "connect"])
  // Only a connect folds: a disconnect after a disconnect still queues.
  q = Model.queueAppend([{ verb: "disconnect" }], { verb: "disconnect" })
  assert.equal(q.length, 2)
  q = Model.queueAppend([tokyo], { verb: "disconnect" })
  assert.deepEqual(q.map(j => j.verb), ["connect", "disconnect"])
  // Never mutates the queue it was handed.
  const original = [tokyo]
  assert.deepEqual(Model.queueAppend(original, paris), [paris])
  assert.deepEqual(original, [tokyo])
  // Degenerate inputs behave like a plain push.
  assert.deepEqual(Model.queueAppend(null, tokyo), [tokyo])
  assert.deepEqual(Model.queueAppend([null], tokyo), [null, tokyo])
})

test("needsFollowUpRefresh drops the extra poll only after a connect/disconnect that settled", () => {
  // The whole point: connect and disconnect now answer with a snapshot.
  assert.equal(Model.needsFollowUpRefresh("connect", true, "connected"), false)
  assert.equal(Model.needsFollowUpRefresh("disconnect", true, "disconnected"), false)
  // Either verb can land on the other state (a disconnect racing an external
  // connect) and still be definite.
  assert.equal(Model.needsFollowUpRefresh("connect", true, "disconnected"), false)
  assert.equal(Model.needsFollowUpRefresh("disconnect", true, "connected"), false)
  // The helper's follow-up `status` failed: agvpn.py answers state "unknown"
  // and the poll is what finds out where we ended up.
  assert.equal(Model.needsFollowUpRefresh("connect", true, "unknown"), true)
  assert.equal(Model.needsFollowUpRefresh("disconnect", true, "unknown"), true)
  assert.equal(Model.needsFollowUpRefresh("connect", true, ""), true)
  // Mid-flight and logged out are not settled answers either.
  assert.equal(Model.needsFollowUpRefresh("connect", true, "connecting"), true)
  assert.equal(Model.needsFollowUpRefresh("connect", true, "logged_out"), true)
  // Failures always poll — the state is whatever it was before.
  assert.equal(Model.needsFollowUpRefresh("connect", false, "connected"), true)
  assert.equal(Model.needsFollowUpRefresh("disconnect", false, "disconnected"), true)
  // Every other action verb keeps the poll; logout reports no snapshot.
  assert.equal(Model.needsFollowUpRefresh("logout", true, "logged_out"), true)
  assert.equal(Model.needsFollowUpRefresh("logout", true, "disconnected"), true)
  assert.equal(Model.needsFollowUpRefresh(undefined, true, "connected"), true)
  // A truthy-but-not-true ok is not a success.
  assert.equal(Model.needsFollowUpRefresh("connect", 1, "connected"), true)
})

test("a connect whose follow-up status failed keeps the last state without claiming an error", () => {
  const src = require("node:fs").readFileSync(require("node:path").join(__dirname, "..", "Service.qml"), "utf8")
  assert.match(src, /function applySnapshot\(obj, requested, verb\)/)
  assert.match(src, /applySnapshot\(obj, verb === "disconnect", verb\)/)
  const unknown = /if \(snap\.state === "unknown"\) \{[\s\S]*?\n    \}/.exec(src)
  assert.ok(unknown, "the unknown branch is there")
  assert.match(unknown[0], /var fromAction = verb === "connect" \|\| verb === "disconnect"/)
  assert.match(unknown[0], /if \(!fromAction && !Model\.errorProtected\(errorSource\)\)/)
  // It still returns without touching vpnState, so the last state stands.
  assert.doesNotMatch(unknown[0], /vpnState =/)
  assert.match(src, /Model\.needsFollowUpRefresh\(verb, ok, ok \? Model\.normalizeSnapshot\(obj\)\.state : ""\)/)
  // normalizeSnapshot is what maps agvpn.py's blank_snapshot("unknown").
  assert.equal(Model.normalizeSnapshot({ ok: true, state: "unknown", location: null }).state, "unknown")
})

test("locationsFresh reuses a recent list and refetches an old, empty or never-loaded one", () => {
  const now = 1_700_000_000_000
  const ttl = Model.LOCATIONS_TTL_MS
  assert.equal(ttl, 5 * 60 * 1000)
  assert.equal(Model.locationsFresh(80, now - 1000, now, ttl), true)
  assert.equal(Model.locationsFresh(80, now - (ttl - 1), now, ttl), true)
  // Exactly at the TTL is stale, so the boundary never reuses a list twice.
  assert.equal(Model.locationsFresh(80, now - ttl, now, ttl), false)
  assert.equal(Model.locationsFresh(80, now - (ttl + 1), now, ttl), false)
  // Nothing loaded yet, or a list that came back empty: always fetch.
  assert.equal(Model.locationsFresh(0, now - 1000, now, ttl), false)
  assert.equal(Model.locationsFresh(80, 0, now, ttl), false)
  // A clock that jumped backwards must not freeze the list.
  assert.equal(Model.locationsFresh(80, now + 60_000, now, ttl), false)
  // Junk arguments fall back to "fetch", never to "skip forever".
  assert.equal(Model.locationsFresh(null, null, now, ttl), false)
  assert.equal(Model.locationsFresh(80, "nope", now, ttl), false)
  // maxAgeMs defaults to the constant when it isn't given.
  assert.equal(Model.locationsFresh(80, now - 1000, now), true)
  assert.equal(Model.locationsFresh(80, now - (ttl + 1), now), false)
})

test("Service.qml skips a fresh locations refresh but never one that was asked for", () => {
  const fs = require("node:fs"), path = require("node:path")
  const src = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
  assert.match(src, /function refreshLocations\(force\)/)
  assert.match(src, /force !== true && Model\.locationsFresh\(locations\.length, _locationsAt, Date\.now\(\), Model\.LOCATIONS_TTL_MS\)/)
  assert.match(src, /function refreshAll\(force\)/)
  assert.match(src, /refreshLocations\(force === true\)/)
  assert.match(src, /_locationsAt = Date\.now\(\)/)
  // Every explicit refresh path in the panel forces the refetch; the panel
  // open (onPanelOpenChanged) is the one that must not.
  const panel = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")
  const calls = panel.match(/refreshAll\([^)]*\)/g) || []
  assert.equal(calls.length, 4)
  for (const call of calls) assert.equal(call, "refreshAll(true)")
  assert.match(src, /if \(panelOpen\) \{ refreshAll\(\); return \}/)
})

test("Service.qml starts up with the snapshot first in the queue", () => {
  const src = require("node:fs").readFileSync(require("node:path").join(__dirname, "..", "Service.qml"), "utf8")
  const block = /Component\.onCompleted:\s*\{[\s\S]*?\n  \}/.exec(src)
  assert.ok(block, "Component.onCompleted present")
  const body = block[0]
  const at = name => body.indexOf(name)
  assert.ok(at("refresh()") !== -1, "enqueues a snapshot")
  assert.ok(at("refresh()") < at("refreshHomeCache()"), "snapshot before the home cache read")
  assert.ok(at("refresh()") < at("refreshLocations()"), "snapshot before the 24 s locations refresh")
  // The privacy gate and its setting guard stay exactly as they were.
  assert.match(body, /maybeRefreshHome\(\)/)
  assert.match(body, /if \(locateHome\) refreshHomeCache\(\)/)
})

test("Service.qml uses tunnel.log's FileView as a trigger only, and urgent snapshots jump the queue", () => {
  const src = require("node:fs").readFileSync(require("node:path").join(__dirname, "..", "Service.qml"), "utf8")
  const block = /FileView\s*\{[\s\S]*?\n  \}/.exec(src)
  assert.ok(block, "FileView present")
  assert.match(block[0], /preload:\s*false/)
  assert.match(block[0], /watchChanges:\s*root\.watchingTunnelLog/)
  assert.doesNotMatch(block[0], /blockLoading:\s*true|onLoaded|reload\(/)
  assert.doesNotMatch(src, /tunnelLogWatch\.(text|data|reload)\s*\(/)
  assert.match(src, /Model\.queueFront\(_queue, \{ args: \["snapshot"\], verb: "snapshot"/)
  assert.match(src, /prevState: _lossBase/)
})
