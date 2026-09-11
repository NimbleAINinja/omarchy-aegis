// Pure data helpers for the Aegis panel: snapshot/location normalisation,
// ordering, search, and label formatting. ES5 only — shared by QML (Qt's JS
// engine, qmllint) and the node tests. No QML or DOM dependencies.

var STATES = ["connected", "connecting", "disconnected", "logged_out"]
var BAR_MODES = ["icon", "iso", "rate"]
var MAX_FAVORITES = 16

// Qt hands QML arrays over as array-likes that fail Array.isArray.
function toList(value) {
  if (value === null || value === undefined) return []
  if (Array.isArray(value)) return value.slice()
  if (typeof value === "object" && typeof value.length === "number") {
    var out = []
    for (var i = 0; i < value.length; i++) out.push(value[i])
    return out
  }
  return []
}

function str(value) {
  return value === null || value === undefined ? "" : String(value)
}

function num(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

function normalizeSnapshot(obj) {
  var o = obj && typeof obj === "object" ? obj : {}
  var state = str(o.state)
  // Output the helper could not parse says nothing about the tunnel; reading
  // it as "disconnected" would fire the drop path on a CLI wording change.
  if (STATES.indexOf(state) === -1) state = "unknown"
  var endpoint = null
  if (o.endpoint && typeof o.endpoint === "object") {
    endpoint = {
      ip: str(o.endpoint.ip),
      port: num(o.endpoint.port, 0),
      pingMs: o.endpoint.pingMs === null || o.endpoint.pingMs === undefined ? null : num(o.endpoint.pingMs, null)
    }
  }
  return {
    ok: o.ok === true,
    state: state,
    location: str(o.location),
    iso: str(o.iso).toUpperCase(),
    iface: str(o.iface),
    mode: str(o.mode).toLowerCase() === "socks" ? "socks" : "tun",
    listen: o.listen === null || o.listen === undefined || str(o.listen) === "" ? null : str(o.listen),
    endpoint: endpoint,
    sinceEpoch: num(o.sinceEpoch, 0),
    rx: num(o.rx, 0),
    tx: num(o.tx, 0),
    error: str(o.error),
    code: str(o.code)
  }
}

function normalizeLocation(raw) {
  var r = raw && typeof raw === "object" ? raw : {}
  var city = str(r.city)
  var ping = r.pingMs === null || r.pingMs === undefined || r.pingMs === "" ? null : num(r.pingMs, null)
  return {
    iso: str(r.iso).toUpperCase(),
    country: str(r.country),
    city: city,
    cliName: str(r.cliName) || city,
    pingMs: ping,
    virtual: r.virtual === true,
    lat: r.lat === null || r.lat === undefined ? null : num(r.lat, null),
    lon: r.lon === null || r.lon === undefined ? null : num(r.lon, null)
  }
}

function normalizeLocations(obj) {
  if (!obj || typeof obj !== "object" || obj.ok === false) return []
  var list = toList(obj.locations).map(normalizeLocation)
  list.sort(function (a, b) {
    if (a.pingMs === null && b.pingMs === null) return 0
    if (a.pingMs === null) return 1
    if (b.pingMs === null) return -1
    return a.pingMs - b.pingMs
  })
  return list
}

function locationKey(loc) {
  if (!loc) return ""
  return str(loc.iso) + "|" + str(loc.city)
}

function copyLocation(loc) {
  var out = {}
  for (var k in loc) if (Object.prototype.hasOwnProperty.call(loc, k)) out[k] = loc[k]
  return out
}

function orderLocations(list, favorites, lastLocation) {
  var items = toList(list)
  var favs = toList(favorites).map(str)
  var last = str(lastLocation)
  var byKey = {}
  for (var i = 0; i < items.length; i++) byKey[locationKey(items[i])] = items[i]
  var out = []
  var used = {}
  for (var f = 0; f < favs.length; f++) {
    var hit = byKey[favs[f]]
    if (!hit || used[favs[f]]) continue
    used[favs[f]] = true
    var fav = copyLocation(hit)
    fav.favorite = true
    fav.last = fav.city === last
    out.push(fav)
  }
  for (var j = 0; j < items.length; j++) {
    var key = locationKey(items[j])
    if (used[key]) continue
    var rest = copyLocation(items[j])
    rest.favorite = false
    rest.last = rest.city === last
    out.push(rest)
  }
  return out
}

// Romanian/Hungarian/Turkish letters that NFD alone would not cover on
// engines lacking String.prototype.normalize.
var FOLD_MAP = {
  "ș": "s", "ş": "s", "ț": "t", "ţ": "t", "ă": "a", "â": "a", "î": "i", "ő": "o", "ű": "u",
  "á": "a", "à": "a", "ä": "a", "ã": "a", "å": "a", "é": "e", "è": "e", "ê": "e", "ë": "e",
  "í": "i", "ì": "i", "ï": "i", "ó": "o", "ò": "o", "ö": "o", "ô": "o", "õ": "o", "ø": "o",
  "ú": "u", "ù": "u", "ü": "u", "û": "u", "ç": "c", "ñ": "n", "ý": "y", "ß": "ss"
}

function foldText(text, allowNormalize) {
  var s = str(text).toLowerCase()
  if (allowNormalize !== false && typeof s.normalize === "function") {
    s = s.normalize("NFD").replace(/[̀-ͯ]/g, "")
  }
  var out = ""
  for (var i = 0; i < s.length; i++) {
    var ch = s.charAt(i)
    out += FOLD_MAP[ch] !== undefined ? FOLD_MAP[ch] : ch
  }
  return out
}

function filterLocations(list, query) {
  var items = toList(list)
  var q = foldText(query).replace(/^\s+|\s+$/g, "")
  if (q === "") return items
  return items.filter(function (loc) {
    var hay = foldText(loc.city) + " " + foldText(loc.country) + " " + foldText(loc.iso)
    return hay.indexOf(q) !== -1
  })
}

function toggleFavorite(favorites, key) {
  var favs = toList(favorites).map(str)
  var k = str(key)
  if (k === "") return favs
  var idx = favs.indexOf(k)
  if (idx !== -1) {
    favs.splice(idx, 1)
    return favs
  }
  favs.push(k)
  while (favs.length > MAX_FAVORITES) favs.shift()
  return favs
}

function pingTier(ms) {
  if (ms === null || ms === undefined) return "none"
  var n = Number(ms)
  if (!isFinite(n)) return "none"
  if (n < 60) return "good"
  if (n < 150) return "ok"
  return "poor"
}

function formatRate(bytesPerSec) {
  var v = num(bytesPerSec, 0)
  if (v <= 0) return "0"
  if (v < 1024) return String(Math.round(v))
  var units = ["K", "M", "G", "T"]
  var u = -1
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024
    u++
  }
  // 1023.9 would round to "1024K"; promote it to the next unit instead.
  if (Math.round(v) >= 1024 && u < units.length - 1) {
    v /= 1024
    u++
  }
  if (v < 10) return v.toFixed(1) + units[u]
  return String(Math.round(v)) + units[u]
}

function formatUptime(sinceEpochSec, nowMs) {
  var since = num(sinceEpochSec, 0)
  if (since <= 0) return ""
  var secs = Math.max(0, Math.floor(num(nowMs, 0) / 1000 - since))
  var d = Math.floor(secs / 86400)
  var h = Math.floor((secs % 86400) / 3600)
  var m = Math.floor((secs % 3600) / 60)
  var s = secs % 60
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m"
  return s + "s"
}

function rateFrom(prev, next, dtMs) {
  var dt = num(dtMs, 0)
  if (!prev || !next || dt <= 0) return { down: 0, up: 0 }
  var down = (num(next.rx, 0) - num(prev.rx, 0)) / (dt / 1000)
  var up = (num(next.tx, 0) - num(prev.tx, 0)) / (dt / 1000)
  return { down: down > 0 ? down : 0, up: up > 0 ? up : 0 }
}

function barLabel(mode, snap, rates) {
  var connected = snap && snap.state === "connected"
  if (!connected) return ""
  if (mode === "iso") return str(snap.iso)
  if (mode === "rate") {
    var r = rates || { down: 0, up: 0 }
    return "↓" + formatRate(r.down) + " ↑" + formatRate(r.up)
  }
  return ""
}

function nextBarMode(mode) {
  var idx = BAR_MODES.indexOf(str(mode))
  if (idx === -1) return BAR_MODES[0]
  return BAR_MODES[(idx + 1) % BAR_MODES.length]
}

function heroMeta(snap, nowMs, countryLookup) {
  if (!snap || snap.state !== "connected") return ""
  var parts = []
  var country = typeof countryLookup === "function" ? str(countryLookup(str(snap.iso))) : ""
  if (country !== "") parts.push(country)
  if (snap.endpoint && snap.endpoint.pingMs !== null && snap.endpoint.pingMs !== undefined && isFinite(Number(snap.endpoint.pingMs))) {
    parts.push(Math.round(Number(snap.endpoint.pingMs)) + " ms")
  }
  var up = formatUptime(snap.sinceEpoch, nowMs)
  if (up !== "") parts.push(up)
  if (str(snap.mode).toLowerCase() === "socks") parts.push("SOCKS" + (snap.listen ? " " + str(snap.listen) : ""))
  return parts.join(" · ")
}

var TZ_TABLE = {
  "America/New_York": [40.71, -74.01],
  "America/Chicago": [41.88, -87.63],
  "America/Denver": [39.74, -104.99],
  "America/Los_Angeles": [34.05, -118.24],
  "America/Phoenix": [33.45, -112.07],
  "America/Toronto": [43.65, -79.38],
  "America/Vancouver": [49.28, -123.12],
  "America/Sao_Paulo": [-23.55, -46.63],
  "America/Mexico_City": [19.43, -99.13],
  "America/Detroit": [42.33, -83.05],
  "America/Indiana/Indianapolis": [39.77, -86.16],
  "US/Eastern": [40.71, -74.01],
  "US/Central": [41.88, -87.63],
  "US/Pacific": [34.05, -118.24],
  "Europe/London": [51.51, -0.13],
  "Europe/Paris": [48.86, 2.35],
  "Europe/Berlin": [52.52, 13.41],
  "Europe/Amsterdam": [52.37, 4.90],
  "Europe/Stockholm": [59.33, 18.07],
  "Europe/Oslo": [59.91, 10.75],
  "Europe/Helsinki": [60.17, 24.94],
  "Europe/Madrid": [40.42, -3.70],
  "Europe/Rome": [41.90, 12.50],
  "Europe/Warsaw": [52.23, 21.01],
  "Europe/Prague": [50.08, 14.44],
  "Europe/Vienna": [48.21, 16.37],
  "Europe/Zurich": [47.38, 8.54],
  "Europe/Lisbon": [38.72, -9.14],
  "Europe/Dublin": [53.35, -6.26],
  "Europe/Athens": [37.98, 23.73],
  "Europe/Istanbul": [41.01, 28.98],
  "Europe/Moscow": [55.76, 37.62],
  "Africa/Cairo": [30.04, 31.24],
  "Africa/Johannesburg": [-26.20, 28.04],
  "Africa/Lagos": [6.52, 3.38],
  "Africa/Nairobi": [-1.29, 36.82],
  "Asia/Tokyo": [35.68, 139.69],
  "Asia/Seoul": [37.57, 126.98],
  "Asia/Shanghai": [31.23, 121.47],
  "Asia/Hong_Kong": [22.32, 114.17],
  "Asia/Singapore": [1.35, 103.82],
  "Asia/Kolkata": [22.57, 88.36],
  "Asia/Calcutta": [22.57, 88.36],
  "Asia/Dubai": [25.20, 55.27],
  "Asia/Jakarta": [-6.21, 106.85],
  "Asia/Bangkok": [13.76, 100.50],
  "Asia/Taipei": [25.03, 121.57],
  "Asia/Jerusalem": [31.77, 35.21],
  "Asia/Tel_Aviv": [32.08, 34.78],
  "Australia/Sydney": [-33.87, 151.21],
  "Australia/Melbourne": [-37.81, 144.96],
  "Pacific/Auckland": [-36.85, 174.76],
  "UTC": [0, 0]
}

// Reduce whatever the timezone source handed us to a bare IANA name so it
// can be looked up in TZ_TABLE. Service.qml reads /etc/localtime (or $TZ)
// with `readlink -f`, which yields a full path like
// "/usr/share/zoneinfo/Asia/Tokyo" — never a bare "Asia/Tokyo" — so without
// this the table lookup never matches. Also strips the "posix/" and
// "right/" alternate-tree prefixes some distros use, and stray whitespace.
function normalizeTimezone(tz) {
  var s = str(tz).replace(/^\s+|\s+$/g, "")
  var zi = s.lastIndexOf("zoneinfo/")
  if (zi !== -1) s = s.substring(zi + "zoneinfo/".length)
  s = s.replace(/^(posix|right)\//, "")
  return s.replace(/\/+$/, "")
}

function homeFromTimezone(tz) {
  var name = normalizeTimezone(tz)
  if (name !== "" && TZ_TABLE[name]) return { lat: TZ_TABLE[name][0], lon: TZ_TABLE[name][1] }
  if (name !== "") {
    // Last-ditch fallback for a zone that isn't a TZ_TABLE key at all (e.g.
    // a distro-local alias/symlink). Anchored to the city — the last path
    // segment — so a real, merely-unlisted IANA region/city never matches
    // an unrelated one just because a loose substring happened to appear
    // somewhere in the full name: "Pacific/Auckland" must never fall
    // through to the US Pacific rule below.
    var city = name.substring(name.lastIndexOf("/") + 1)
    if (city.indexOf("Stockholm") !== -1) return { lat: 59.33, lon: 18.07 }
    if (city.indexOf("London") !== -1) return { lat: 51.51, lon: -0.13 }
    if (city === "Pacific" || city.indexOf("Los_Angeles") !== -1) return { lat: 34.05, lon: -118.24 }
    if (city === "Eastern" || city.indexOf("New_York") !== -1) return { lat: 40.71, lon: -74.01 }
  }
  return { lat: 48, lon: 10 }
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(String(value === null || value === undefined ? "" : value), 10)
  if (!isFinite(n)) n = fallback
  if (n < min) n = min
  if (n > max) n = max
  return n
}

function findLocation(list, city) {
  var want = foldText(str(city))
  if (want === "") return null
  var items = toList(list)
  for (var i = 0; i < items.length; i++) {
    if (items[i] && foldText(str(items[i].city)) === want) return items[i]
  }
  return null
}

function loggedOutAccount() {
  return { loggedIn: false, email: "", plan: "", devices: null, validUntil: null }
}

function normalizeAccount(obj) {
  var o = obj && typeof obj === "object" ? obj : {}
  if (o.loggedIn !== true) return loggedOutAccount()
  return {
    loggedIn: true,
    email: str(o.email),
    plan: str(o.plan),
    devices: o.devices === null || o.devices === undefined ? null : num(o.devices, null),
    validUntil: o.validUntil === null || o.validUntil === undefined ? null : str(o.validUntil)
  }
}

function normalizeExclusions(obj) {
  var o = obj && typeof obj === "object" ? obj : {}
  var mode = str(o.mode).toLowerCase()
  if (mode !== "general" && mode !== "selective") mode = "general"
  var seen = {}
  var domains = []
  var raw = toList(o.domains)
  for (var i = 0; i < raw.length; i++) {
    var d = str(raw[i]).trim()
    if (d === "" || seen[d]) continue
    seen[d] = true
    domains.push(d)
  }
  return { mode: mode, domains: domains }
}

function isFavorite(favorites, loc) {
  if (!loc) return false
  return toList(favorites).map(str).indexOf(locationKey(loc)) !== -1
}

var MODES = ["tun", "socks"]
var PROTOCOLS = ["auto", "http2", "quic"]
var APP_NAME = /^[A-Za-z0-9._+-]{1,64}$/

// Process names a VPN kill switch must never offer or touch, checked
// case-insensitively. Keep this in sync with PROCS_DENY / PROCS_DENY_PREFIXES
// in agvpn.py (that file points back here) — the CLI helper is the one that
// actually calls pkill and enforces this too, but the UI should never even
// offer these names as suggestions or accept them into killApps.
var PROCS_DENY = [
  "sh", "bash", "zsh", "fish", "dash", "python3", "python", "ps",
  "systemd", "init", "sddm", "gdm", "gdm3", "lightdm", "login", "agetty",
  "dbus-daemon", "dbus-broker", "pipewire", "wireplumber",
  "hyprland", "quickshell", "qs", "omarchy-shell",
  // Idle/lock and Wayland/session plumbing: killing hyprlock on a VPN drop
  // would UNLOCK the session instead of protecting it, so it (and the idle
  // daemon that triggers it) must never be offered or accepted.
  "hyprlock", "hypridle", "uwsm", "xwayland",
  "polkitd", "hyprpolkitagent", "gnome-keyring-daemon", "ssh-agent", "gpg-agent",
  // The kill switch's own notification depends on this notification daemon
  // (Service.qml's notify() → `omarchy notification send`); swayosd is the
  // volume/brightness OSD and walker/elephant the app launcher, all
  // session-critical enough not to offer.
  "mako", "swayosd-server", "walker", "elephant",
  "adguardvpn-cli", "sudo", "env"
]
var PROCS_DENY_PREFIXES = ["dbus-broker", "systemd-", "pipewire", "polkit", "xdg-desktop"]

// The kernel truncates a process's comm to this many bytes; `ps` and
// `pkill -x` only ever see that truncation. Kept in sync with COMM_LEN /
// PROCS_DENY_TRUNCATED in agvpn.py's _is_denied.
var COMM_LEN = 15
var PROCS_DENY_TRUNCATED = []
for (var _pi = 0; _pi < PROCS_DENY.length; _pi++) {
  if (PROCS_DENY[_pi].length > COMM_LEN) PROCS_DENY_TRUNCATED.push(PROCS_DENY[_pi].slice(0, COMM_LEN))
}

function isDeniedApp(name) {
  var lower = str(name).toLowerCase()
  if (PROCS_DENY.indexOf(lower) !== -1) return true
  for (var i = 0; i < PROCS_DENY_PREFIXES.length; i++) {
    if (lower.indexOf(PROCS_DENY_PREFIXES[i]) === 0) return true
  }
  // A name that IS the truncated comm of a longer denied name (e.g.
  // "gnome-keyring-d" for "gnome-keyring-daemon") must be refused too:
  // pkill -x on it would still hit the real, longer-named process.
  if (lower.length === COMM_LEN && PROCS_DENY_TRUNCATED.indexOf(lower) !== -1) return true
  return false
}

function normalizeConfig(obj) {
  var o = obj && typeof obj === "object" ? obj : {}
  var mode = str(o.mode).toLowerCase()
  if (MODES.indexOf(mode) === -1) mode = "tun"
  var protocol = str(o.protocol).toLowerCase()
  if (PROTOCOLS.indexOf(protocol) === -1) protocol = "auto"
  var port = parseInt(str(o.socksPort), 10)
  if (!isFinite(port) || port < 1 || port > 65535) port = 1080
  var dns = str(o.dns).trim()
  return {
    mode: mode,
    socksHost: str(o.socksHost),
    socksPort: port,
    socksUsername: str(o.socksUsername),
    dns: dns === "" ? "default" : dns,
    changeSystemDns: o.changeSystemDns === true,
    protocol: protocol,
    postQuantum: o.postQuantum !== false,
    showHints: o.showHints !== false
  }
}

// Config keys whose value is a secret. It must never ride a command line:
// /proc/<pid>/cmdline is readable by every local user for as long as the
// helper and its adguardvpn-cli run (up to a CLI lock wait). agvpn.py takes
// these on stdin behind a "-" and refuses a value on argv; keep this list in
// sync with its "stdin" CONFIG_SETTERS (tests/model.test.js checks it).
var CONFIG_STDIN_KEYS = ["socksPassword"]

// The helper job for Service.setConfig: { args, stdin }. For a secret key
// args carry "-" where the value would go and stdin holds the value (see
// Service.qml's jobProcess); for everything else stdin is null.
function configJob(key, value) {
  var k = String(key)
  if (CONFIG_STDIN_KEYS.indexOf(k) !== -1) return { args: ["config", "set", k, "-"], stdin: str(value) }
  return { args: ["config", "set", k, String(value)], stdin: null }
}

function normalizeUpdate(obj) {
  var o = obj && typeof obj === "object" ? obj : {}
  return {
    upToDate: o.upToDate !== false,
    current: str(o.current),
    latest: o.latest === null || o.latest === undefined || str(o.latest) === "" ? null : str(o.latest),
    checkedAt: num(o.checkedAt, 0)
  }
}

function parseAppList(text) {
  var parts = str(text).split(/[\s,;]+/)
  var seen = {}
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var name = parts[i].trim()
    if (name === "" || !APP_NAME.test(name) || isDeniedApp(name) || seen[name]) continue
    seen[name] = true
    out.push(name)
  }
  return out
}

function formatAppList(list) {
  return toList(list).map(str).join(", ")
}

// A tunnel that was up and is now down: a "disconnect" when the user asked
// for it (Disconnect or logout), a "drop" otherwise; "" for anything else.
// Logged out without a request is left alone, as before.
function tunnelLoss(prevState, nextState, requested) {
  if (prevState !== "connected") return ""
  if (nextState === "disconnected") return requested === true ? "disconnect" : "drop"
  if (nextState === "logged_out" && requested === true) return "disconnect"
  return ""
}

// One definite status arriving, decided in a fixed order: the loss is judged
// from the pending toggle as it was when the status came in, before that
// toggle settles (settling first turned every Disconnect into a drop).
//   ctx: { prevState, nextState, desired: -1|0|1, requested, wasConnected }
//   → { desired, loss, wasConnected: true | false | null (leave it) }
// wasConnected is only set while no disconnect is pending, and cleared by a
// requested disconnect, never by a drop, so reconnect-at-login survives drops.
function settleStatus(ctx) {
  var c = ctx && typeof ctx === "object" ? ctx : {}
  var next = str(c.nextState)
  var pending = c.desired === 0 || c.desired === 1 ? c.desired : -1
  var loss = tunnelLoss(c.prevState, next, pending === 0 || c.requested === true)
  var desired = (pending === 1 && next === "connected") || (pending === 0 && next === "disconnected") ? -1 : pending
  var was = null
  if (next === "connected" && pending !== 0 && c.wasConnected !== true) was = true
  if (loss === "disconnect" && c.wasConnected === true) was = false
  return { desired: desired, loss: loss, wasConnected: was }
}

// Whether the standing lastError/errorCode should survive a routine/
// background outcome (a status snapshot that parsed fine, or one that
// didn't) instead of being cleared or papered over by it. "action": raised
// by a user-initiated action (connect/disconnect/exclusion/config change).
// "sudo": the sudo-password warning. Both are only replaced by the user
// starting a new action (Service clears eagerly there) or by dismissal;
// anything else ("" or "parse") a good background snapshot is free to clear.
function errorProtected(source) {
  return source === "action" || source === "sudo"
}

// Whether a fresh, recognised status snapshot proves that a failed connect/
// disconnect action's outcome happened anyway (the CLI finished after a
// watchdog timeout, auto-connect's network blip cleared up, ...), so its
// "action" error can be cleared without the user starting another action.
//   intent: { verb: "connect", target } | { verb: "disconnect" } | null
//   snap: { state, location }
// A connect only resolves against a snapshot connected to that same
// location — being connected to somewhere else must not clear a
// "location not found" (or similar) error about the original target.
function errorResolved(intent, snap) {
  if (!intent || typeof intent !== "object" || !snap || typeof snap !== "object") return false
  if (intent.verb === "connect") {
    // pendingLocation (the UI's city, or a raw CLI name typed via IPC
    // `connect <city>`) and the helper's matched city name can differ only
    // in case/whitespace — that must still count as the same place.
    var target = str(intent.target).replace(/^\s+|\s+$/g, "").toLowerCase()
    var got = str(snap.location).replace(/^\s+|\s+$/g, "").toLowerCase()
    return target !== "" && snap.state === "connected" && got === target
  }
  if (intent.verb === "disconnect") return snap.state === "disconnected"
  return false
}

function shouldAutoConnect(ctx) {
  if (!ctx || typeof ctx !== "object") return false
  return ctx.autoConnect === true && ctx.wasConnected === true && !ctx.attempted
    && ctx.installed === true && ctx.loggedIn !== false && ctx.state === "disconnected"
}

// Whether a home-location lookup (ipinfo.io, run by agvpn.py's `home` verb)
// may fire right now. The setting alone isn't enough: even with it on, a
// lookup may only run once the tunnel is down by the user's own choice —
//   - never before the first status has settled (state is still "unknown",
//     or the very first snapshot hasn't been judged yet)
//   - never while startup's auto-connect is about to reconnect a VPN that
//     was on last session (Model.shouldAutoConnect said yes and that
//     connect hasn't finished or failed yet) — the first lookup at login
//     waits until it's clear the VPN will stay off
//   - never after an unexpected drop, until the user takes some explicit
//     action (connect, disconnect, toggle) — an intentional disconnect or
//     logout is fine, the user chose the clear net that time
//   ctx: { locateHome, state, startupSettled, autoConnectPending, dropHold }
function mayLocateHome(ctx) {
  var c = ctx && typeof ctx === "object" ? ctx : {}
  if (c.locateHome !== true) return false
  if (c.startupSettled !== true) return false
  if (c.autoConnectPending === true) return false
  if (c.dropHold === true) return false
  return c.state === "disconnected"
}

function updateCheckDue(lastCheckEpochSec, nowMs, intervalSec) {
  var last = num(lastCheckEpochSec, 0)
  if (last <= 0) return true
  var interval = num(intervalSec, 86400)
  return num(nowMs, 0) / 1000 - last > interval
}

function protocolLabel(protocol) {
  var p = str(protocol).toLowerCase()
  if (p === "http2") return "HTTP/2"
  if (p === "quic") return "QUIC"
  return "Auto"
}

function dnsLabel(dns) {
  var d = str(dns).trim()
  return d === "" || d.toLowerCase() === "default" ? "AdGuard" : d
}

function describeDrop(location) {
  var where = str(location).trim()
  return where === "" ? "Tunnel dropped" : "Tunnel to " + where + " dropped"
}

function describeDisconnect(location) {
  var where = str(location).trim()
  return where === "" ? "Disconnected" : "Disconnected from " + where
}

// What a tunnel loss does. A drop always alerts (critical) and closes the
// apps when the kill switch is armed; a requested disconnect closes them, with
// a normal notice, only when killOnDisconnect is on too. null: stay quiet.
//   ctx: { location, killSwitch, killOnDisconnect, apps }
//   → { kill: [names], title, body, urgency }
function lossResponse(kind, ctx) {
  var c = ctx && typeof ctx === "object" ? ctx : {}
  var apps = c.killSwitch === true ? toList(c.apps).map(str) : []
  var closed = apps.length > 0 ? " · closed " + formatAppList(apps) : ""
  if (kind === "drop")
    return { kill: apps, title: "VPN dropped", body: describeDrop(c.location) + closed, urgency: "critical" }
  if (kind === "disconnect" && c.killOnDisconnect === true && apps.length > 0)
    return { kill: apps, title: "VPN disconnected", body: describeDisconnect(c.location) + closed, urgency: "normal" }
  return null
}

function filterProcs(procs, query, chosen, limit) {
  var q = str(query).trim().toLowerCase()
  if (q === "") return []
  var max = limit === undefined || limit === null ? 6 : Math.max(0, Number(limit) || 0)
  var taken = {}
  var chosenList = toList(chosen).map(str)
  for (var c = 0; c < chosenList.length; c++) taken[chosenList[c]] = true
  var prefix = []
  var inner = []
  var items = toList(procs)
  var seen = {}
  for (var i = 0; i < items.length; i++) {
    var name = str(items[i]).trim()
    if (name === "" || taken[name] || seen[name]) continue
    seen[name] = true
    var lower = name.toLowerCase()
    var at = lower.indexOf(q)
    if (at === 0) prefix.push(name)
    else if (at > 0) inner.push(name)
  }
  var byLower = function(a, b) {
    var la = a.toLowerCase(), lb = b.toLowerCase()
    return la < lb ? -1 : (la > lb ? 1 : 0)
  }
  prefix.sort(byLower)
  inner.sort(byLower)
  return prefix.concat(inner).slice(0, max)
}

// What KillSwitchView's "add app" field should add when the user submits
// it. Tab (and clicking a suggestion, which moves the highlight to the
// clicked row first) always takes the highlighted suggestion — that's the
// autocomplete affordance. Enter takes exactly what was typed, unless the
// user has moved the highlight with Up/Down or the mouse, in which case it
// takes that highlighted suggestion too. Without this distinction, typing
// "steam" while "steamwebhelper" is running would always add
// "steamwebhelper" (the default top match) and the kill switch could never
// be told to close "steam" itself.
//   typed: the field's current text
//   suggestions: the filtered suggestion list, top match first
//   highlightIndex: the currently highlighted row
//   navigated: whether the user moved the highlight since last typing, as
//     opposed to it merely defaulting to the top match
//   key: "tab" | "enter"
// Returns the trimmed name to add, or "" if there is nothing to add.
function chooseKillSwitchName(typed, suggestions, highlightIndex, navigated, key) {
  var text = str(typed).trim()
  var list = toList(suggestions).map(str)
  if (list.length === 0) return text
  var idx = Math.min(Math.max(0, num(highlightIndex, 0)), list.length - 1)
  if (key === "tab" || navigated === true) return list[idx]
  return text
}

function addApp(list, name) {
  var out = toList(list).map(str)
  var clean = str(name).trim()
  if (!APP_NAME.test(clean) || isDeniedApp(clean) || out.indexOf(clean) !== -1) return out
  out.push(clean)
  return out
}

function removeApp(list, name) {
  var clean = str(name).trim()
  return toList(list).map(str).filter(function(item) { return item !== clean })
}

function cleanDomains(value) {
  var seen = {}
  var out = []
  var items = toList(value)
  for (var i = 0; i < items.length; i++) {
    var d = str(items[i]).trim().toLowerCase()
    if (d === "" || seen[d]) continue
    seen[d] = true
    out.push(d)
  }
  return out
}

function normalizePaused(value) {
  var o = value && typeof value === "object" ? value : {}
  return { general: cleanDomains(o.general), selective: cleanDomains(o.selective) }
}

function mergeExclusions(activeDomains, pausedForMode) {
  // One alphabetical order for active and paused alike, so pausing or
  // resuming a row never moves it.
  var active = cleanDomains(activeDomains)
  var paused = cleanDomains(pausedForMode)
  var seen = {}
  var rows = []
  for (var i = 0; i < active.length; i++) {
    if (seen[active[i]]) continue
    seen[active[i]] = true
    rows.push({ domain: active[i], paused: false })
  }
  for (var j = 0; j < paused.length; j++) {
    if (seen[paused[j]]) continue
    seen[paused[j]] = true
    rows.push({ domain: paused[j], paused: true })
  }
  rows.sort(function(a, b) {
    var x = a.domain.toLowerCase(), y = b.domain.toLowerCase()
    return x < y ? -1 : (x > y ? 1 : 0)
  })
  return rows
}

function setPaused(pausedMap, mode, domain, paused) {
  var map = normalizePaused(pausedMap)
  var m = str(mode)
  if (m !== "general" && m !== "selective") return map
  var d = str(domain).trim().toLowerCase()
  if (d === "") return map
  var list = map[m].filter(function(item) { return item !== d })
  if (paused) list.push(d)
  map[m] = list
  return map
}

function exclusionKeys(rows) {
  return toList(rows).map(function(row) { return row && typeof row === "object" ? str(row.domain) : "" })
}

// Case-insensitive lookup of a domain's stored spelling in a CLI-returned
// list. exclusionRows (via mergeExclusions/cleanDomains) always lowercases
// what it shows, but exclusions.domains holds whatever case the CLI itself
// returned — which might not be lowercase for a domain added before this
// normalisation existed, or one the CLI reformatted on its own. Remove/pause
// must hand the CLI back the exact spelling it has on file, or it silently
// does nothing. Returns the stored spelling, or null if it isn't found.
function findExclusionDomain(domains, needle) {
  var want = str(needle).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (want === "") return null
  var list = toList(domains)
  for (var i = 0; i < list.length; i++) {
    if (str(list[i]).replace(/^\s+|\s+$/g, "").toLowerCase() === want) return str(list[i])
  }
  return null
}

// agvpn.py verb_budgets(): each helper verb's overall budget in seconds
// (every sub-call timeout on its longest path, plus one CLI call's worth of
// lock wait). The helper enforces it and answers a timeout itself; this copy
// only sizes Service.qml's jobWatchdog, and tests/model.test.js checks it
// against agvpn.py, so change both together.
var HELPER_BUDGET_SEC = {
  "snapshot": 27, "locations": 24, "connect": 84, "disconnect": 36, "account": 24, "logout": 24,
  "exclusions": 48, "home": 35, "config": 39, "update-check": 36, "procs": 17
}
// On top of a budget: python start-up, reaping a timed-out CLI, the answer.
var WATCHDOG_SLACK_MS = 5000
// Between the watchdog's SIGTERM and its SIGKILL: agvpn.py's STOP_GRACE for
// stopping its CLI child, plus the same slack.
var WATCHDOG_KILL_MS = 8000

// jobWatchdog's interval for a helper verb (the job's args[0], e.g.
// "update-check"), never shorter than the helper's own worst case. An
// unknown verb gets the longest budget.
function watchdogMs(verb) {
  var sec = Object.prototype.hasOwnProperty.call(HELPER_BUDGET_SEC, verb) ? HELPER_BUDGET_SEC[verb] : 0
  if (!sec) for (var k in HELPER_BUDGET_SEC) sec = Math.max(sec, HELPER_BUDGET_SEC[k])
  return sec * 1000 + WATCHDOG_SLACK_MS
}

function elideStatus(text, max) {
  var limit = num(max, 140)
  var value = str(text).replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  if (value.length <= limit) return value
  return value.substring(0, limit - 1) + "…"
}

if (typeof module !== "undefined") {
  module.exports = {
    toList: toList,
    normalizeSnapshot: normalizeSnapshot,
    normalizeLocations: normalizeLocations,
    locationKey: locationKey,
    orderLocations: orderLocations,
    foldText: foldText,
    filterLocations: filterLocations,
    toggleFavorite: toggleFavorite,
    pingTier: pingTier,
    formatRate: formatRate,
    formatUptime: formatUptime,
    rateFrom: rateFrom,
    barLabel: barLabel,
    nextBarMode: nextBarMode,
    heroMeta: heroMeta,
    homeFromTimezone: homeFromTimezone,
    normalizeTimezone: normalizeTimezone,
    elideStatus: elideStatus,
    clampInt: clampInt,
    findLocation: findLocation,
    loggedOutAccount: loggedOutAccount,
    normalizeAccount: normalizeAccount,
    normalizeExclusions: normalizeExclusions,
    isFavorite: isFavorite,
    normalizeConfig: normalizeConfig,
    CONFIG_STDIN_KEYS: CONFIG_STDIN_KEYS,
    configJob: configJob,
    normalizeUpdate: normalizeUpdate,
    parseAppList: parseAppList,
    formatAppList: formatAppList,
    isDeniedApp: isDeniedApp,
    PROCS_DENY: PROCS_DENY,
    PROCS_DENY_PREFIXES: PROCS_DENY_PREFIXES,
    chooseKillSwitchName: chooseKillSwitchName,
    tunnelLoss: tunnelLoss,
    settleStatus: settleStatus,
    errorProtected: errorProtected,
    errorResolved: errorResolved,
    shouldAutoConnect: shouldAutoConnect,
    mayLocateHome: mayLocateHome,
    updateCheckDue: updateCheckDue,
    protocolLabel: protocolLabel,
    dnsLabel: dnsLabel,
    describeDrop: describeDrop,
    describeDisconnect: describeDisconnect,
    lossResponse: lossResponse,
    filterProcs: filterProcs,
    addApp: addApp,
    removeApp: removeApp,
    normalizePaused: normalizePaused,
    mergeExclusions: mergeExclusions,
    setPaused: setPaused,
    exclusionKeys: exclusionKeys,
    findExclusionDomain: findExclusionDomain,
    HELPER_BUDGET_SEC: HELPER_BUDGET_SEC,
    WATCHDOG_SLACK_MS: WATCHDOG_SLACK_MS,
    WATCHDOG_KILL_MS: WATCHDOG_KILL_MS,
    watchdogMs: watchdogMs
  }
}
