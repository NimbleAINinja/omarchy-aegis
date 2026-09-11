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

test("mergeExclusions keeps one stable alphabetical order so pausing never moves a row", () => {
  const rows = Model.mergeExclusions(["news.example.com", "anthropic.com"], ["example.org", "anthropic.com"])
  assert.deepEqual(rows, [
    { domain: "anthropic.com", paused: false },
    { domain: "example.org", paused: true },
    { domain: "news.example.com", paused: false }
  ])
  assert.deepEqual(Model.mergeExclusions([], []), [])
  assert.deepEqual(Model.mergeExclusions(["B.com", "a.com"], []), [{ domain: "a.com", paused: false }, { domain: "b.com", paused: false }], "hostnames are case-insensitive, so rows are lowercased")
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
