import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Headless data layer for Aegis. Owns every process; the panel only reads
// state and calls the action functions. All parsing lives in agvpn.py (JSON)
// and Model.js so this file is wiring, not logic.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  // --- state ------------------------------------------------------------------
  property bool installed: true
  property string vpnState: "unknown"       // connected | connecting | disconnected | logged_out | unknown (until the first recognised status)
  property string location: ""
  property string iso: ""
  property string iface: ""
  property string mode: "tun"            // tun | socks (from status)
  property string listen: ""             // SOCKS listen address when mode is socks
  property var endpoint: null            // { ip, port, pingMs }
  property real sinceEpoch: 0
  property real rx: 0
  property real tx: 0
  property var rates: ({ down: 0, up: 0 })
  // One { down, up } per rate sample for the traffic tab's graph, oldest
  // first, capped at Model.TRAFFIC_CAP. Emptied whenever the tunnel leaves
  // connected — the columns describe one tunnel's traffic, so the next one
  // starts from an empty graph rather than inheriting the old one's peaks.
  property var trafficHistory: []
  property var locations: []
  property var account: ({ loggedIn: true, email: "", plan: "", devices: null, validUntil: null })
  property bool accountLoaded: false
  property var exclusions: ({ mode: "general", domains: [] })
  property var home: null                // { lat, lon, city, iso }
  property bool homeStale: true
  property string timezone: ""
  property string actionStatus: ""
  property string lastError: ""
  property string errorCode: ""
  // What raised lastError/errorCode: "action" (a user-initiated connect/
  // disconnect/exclusion/config call), "sudo", or "" (a routine background
  // outcome, freely replaced). See Model.errorProtected.
  property string errorSource: ""
  // What a connect/disconnect action wanted, so a later snapshot proving it
  // happened anyway (the CLI finished after a watchdog timeout, a network
  // blip cleared up after auto-connect failed, ...) can resolve the error
  // without waiting for the user to start another action. Only ever set
  // alongside errorSource === "action"; null for exclusion/config/sudo
  // errors, which keep the new-action-only rule. See Model.errorResolved.
  //   { verb: "connect", target } | { verb: "disconnect" } | null
  property var errorIntent: null
  property string pendingLocation: ""    // city currently being connected
  // Whether sudo would start the VPN service without a password: "ok",
  // "missing", or "unknown" until the side channel's `sudo-check` has
  // answered (checkSudoRule). A sudo_password error settles it as missing,
  // a connect that went through settles it as ok. Model.setupStep turns it
  // into the hero's notice, and Model.connectNeedsTerminal sends a TUN
  // connect to a terminal while it is missing.
  property string sudoRule: "unknown"
  // Where the adguardvpn-cli binary is, from the side channel's `cli-path`
  // (checkCliPath), or "" until it has answered. Only the commands that go
  // to a terminal need it: everything in here reaches the CLI through the
  // helper, which resolves the path itself. See Model.cliCommand.
  property string cliPath: ""

  // Optimistic switch state: -1 follows reality, 0/1 while an action is in flight.
  property int _desired: -1
  readonly property bool connected: vpnState === "connected"
  readonly property bool active: _desired === -1 ? (vpnState === "connected" || vpnState === "connecting") : _desired === 1
  // "connecting" while a connect is pending even if the CLI still says
  // connected — the old tunnel is on its way out. See Model.linkState.
  readonly property string linkState: Model.linkState(vpnState, pendingLocation)
  readonly property var homePoint: home ? home : Model.homeFromTimezone(timezone)
  readonly property int refreshIntervalSec: Model.clampInt(setting("refreshIntervalSec", 30), 30, 5, 3600)
  readonly property string barMode: String(setting("barMode", "icon"))
  readonly property string lastLocation: String(setting("lastLocation", ""))
  readonly property bool autoConnect: String(setting("autoConnect", true)) === "true"
  readonly property bool wasConnected: String(setting("wasConnected", false)) === "true"
  readonly property bool killSwitch: String(setting("killSwitch", false)) === "true"
  readonly property bool killOnDisconnect: String(setting("killOnDisconnect", false)) === "true"
  readonly property var killApps: Model.parseAppList(setting("killApps", ""))
  readonly property real lastUpdateCheck: Number(setting("lastUpdateCheck", 0)) || 0
  readonly property bool locateHome: String(setting("locateHome", true)) === "true"
  readonly property bool pingDots: String(setting("pingDots", true)) === "true"

  property var procs: []
  readonly property var pausedExclusions: Model.normalizePaused(setting("pausedExclusions", null))
  readonly property var exclusionRows: Model.mergeExclusions(exclusions.domains, pausedExclusions[exclusions.mode] || [])
  property var config: Model.normalizeConfig(null)
  property bool configLoaded: false
  // The mode the next connect will use: the CLI's configured one once
  // `config show` has answered, the status's until then. A disconnected
  // status names no mode (it reads "tun"), so the configured one is what
  // decides whether a connect needs a terminal for sudo — and whether the
  // hero's notice about that applies at all. See Model.connectNeedsTerminal.
  readonly property string nextMode: configLoaded ? config.mode : mode
  property var update: Model.normalizeUpdate(null)
  // Epoch ms after which a failed background update check may retry; 0 means
  // no failure is pending. Not persisted — a fresh shell start always gets
  // its own startup check regardless of a stale backoff from last time.
  property real _updateRetryAt: 0
  property bool autoConnectAttempted: false
  // Auto-connect is decided once, on the first definite status after the
  // shell starts. A drop later in the session notifies (and runs the kill
  // switch) but never reconnects behind the user's back.
  property bool startupSettled: false
  // True from the moment maybeAutoConnect() actually starts a reconnect
  // until that connect job finishes or fails (jobProcess.onExited clears
  // it). While true, Model.mayLocateHome refuses the home lookup: the VPN
  // is about to come back up, so there is nothing to reveal a location for
  // yet, and firing the lookup here is exactly the login-on-cafe-wifi leak.
  property bool autoConnectPending: false
  // True once a snapshot reports the tunnel dropped unexpectedly (Model.
  // settleStatus's "drop"), until the user takes some explicit action
  // (connect, disconnect, toggle — see connectTo/down/logout). Model.
  // mayLocateHome refuses lookups the whole time: right after a drop is
  // exactly when the user expects to be protected, and without this a drop
  // would just defer one snapshot before the next 30s poll looked up anyway.
  property bool dropHold: false

  // --- tunnel.log trigger -------------------------------------------------------
  // The status poll alone (refreshTimer: refreshIntervalSec, doubled while
  // the panel is closed, plus any wait behind queued jobs) left a drop — and
  // the kill switch — unnoticed for a minute or more. The VPN daemon logs
  // every state change to tunnel.log as it happens, so Service watches that
  // file and, on a new raise_state line, gets a snapshot within seconds
  // (scheduleLogScan → scanTunnelLog → applyTunnelLog, Model.tunnelLogAction
  // and confirmDrop). The poll is untouched: it is the fallback whenever the
  // watch can't be set up, and the only detector for a daemon that dies
  // without logging anything.
  //
  // The last settled state a tunnel loss is judged from; see Model.lossBase
  // (kept in step with vpnState by onVpnStateChanged).
  property string _lossBase: "unknown"
  readonly property string tunnelLogPath: Model.tunnelLogPath({ AEGIS_DATA_DIR: Quickshell.env("AEGIS_DATA_DIR"),
    XDG_DATA_HOME: Quickshell.env("XDG_DATA_HOME"), HOME: Quickshell.env("HOME") })
  // Watched whenever the tunnel is up (or recovering from being up), kill
  // switch armed or not: a drop always raises a critical notification and
  // holds the home lookup (dropHold), and both are worth having in seconds.
  // It costs next to nothing — while connected the daemon logs one route
  // line every few minutes, so a look at the tail is rare and a CLI call
  // only follows an actual state line. Nothing to lose while disconnected,
  // so no watch then.
  readonly property bool watchingTunnelLog: installed && tunnelLogPath !== "" && _lossBase === "connected"
  // Model.scanTunnelLog's `seen`: the newest state line the last look found,
  // null until the first look after the watch starts.
  property var _logSeen: null
  // The newest state tunnel.log has shown ("" before any); see confirmDrop.
  property string _logLatest: ""
  // Pulsed by rearmTunnelLog to rebuild the file watch.
  property bool _logRearming: false

  signal actionFinished(string verb, bool ok)
  // Ask the panel (which owns the shell.json entry) to persist inline settings.
  signal persist(var values)
  // First run just finished and the tunnel is on its way up by itself:
  // Panel jumps to the traffic tab once so the user watches it fill. The
  // only connect that moves anyone — see Panel's Connections block.

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function pluginFile(name) {
    return decodeURIComponent(Qt.resolvedUrl(name).toString().replace(/^file:\/\//, ""))
  }

  function helper(args) {
    return ["python3", pluginFile("agvpn.py")].concat(args)
  }

  // --- refresh ---------------------------------------------------------------
  // Every CLI-backed call goes through one serialized queue: adguardvpn-cli
  // aborts when several instances run at once (seen as SIGABRT coredumps of
  // `list-locations` while `status` and `license` were also running).
  function refresh() { enqueue(["snapshot"], "snapshot", true) }

  // When applyLocations last landed a list (epoch ms, 0 = never). Only the
  // TTL below reads it, so it is deliberately not persisted: a fresh shell
  // always fetches once.
  property real _locationsAt: 0
  // `force`: fetch even when the list we have is still fresh. The explicit
  // refresh paths (footer button, `r`, bar middle-click, IPC `refresh`) pass
  // it; a panel open does not — see Model.locationsFresh for why.
  function refreshLocations(force) {
    if (force !== true && Model.locationsFresh(locations.length, _locationsAt, Date.now(), Model.LOCATIONS_TTL_MS)) return
    enqueue(["locations"], "locations", true)
  }
  function refreshAccount() { enqueue(["account"], "account", true) }
  function refreshExclusions() { enqueue(["exclusions", "show"], "exclusions", true) }
  function refreshHome() { enqueue(["home"], "home", true) }

  // The cache-only read (agvpn.py's `home cached`): no CLI call, no network,
  // works whatever the VPN state is — unlike refreshHome() this is never
  // gated by Model.mayLocateHome, only by the locateHome setting itself (see
  // its call sites). A distinct queue verb ("homeCache" vs "home") from
  // refreshHome's so enqueue's dedupe never lets one swallow the other: both
  // jobs run agvpn.py with args[0] "home" (same Model.watchdogMs budget —
  // see HELPER_BUDGET_SEC), but they are different queue entries.
  function refreshHomeCache() { sideEnqueue(["home", "cached"], "homeCache", false) }

  // The only place that decides whether an ipinfo.io lookup may actually
  // run (Model.mayLocateHome) — every call site that used to call
  // refreshHome() directly goes through this instead.
  //   wasConnectedOverride: applySnapshot's own callers pass the value
  //   Model.settleStatus just decided for *this* snapshot (step.wasConnected,
  //   when non-null) — the wasConnected property is only updated by the
  //   persist() a few lines further down in applySnapshot, so reading it
  //   here directly would still see the previous snapshot's value. Every
  //   other caller has no fresher answer than the property itself, so they
  //   leave this undefined.
  function maybeRefreshHome(wasConnectedOverride) {
    var wc = wasConnectedOverride === undefined ? wasConnected : wasConnectedOverride
    if (Model.mayLocateHome({ locateHome: locateHome, state: vpnState, startupSettled: startupSettled,
      autoConnectPending: autoConnectPending, dropHold: dropHold, wasConnected: wc })) refreshHome()
  }

  // `force`: true from the explicit refresh paths (footer button, `r`, bar
  // middle-click, IPC `refresh`), which must really refetch the location
  // list; a plain panel open leaves it undefined and reuses a fresh list.
  function refreshAll(force) {
    refresh()
    refreshLocations(force === true)
    if (!accountLoaded) refreshAccount()
    maybeRefreshHome()
    // Whenever the panel opens (refreshAll's only real caller, plus the "r"
    // shortcut/middle-click/IPC refresh) with locateHome on and no home
    // loaded yet — a shell restart while connected leaves it null, since
    // maybeRefreshHome above is a no-op until the tunnel is down by choice
    // — the cache read can only help and never leaks anything, so it always
    // runs rather than waiting on that.
    if (locateHome && home === null) refreshHomeCache()
    if (sudoRule === "unknown") checkSudoRule()
    // Once: the configured mode is what nextMode reads, and it changes only
    // through setConfig, which refreshes it itself.
    if (!configLoaded) refreshConfig()
  }

  // --- the sudo rule ------------------------------------------------------------
  // A read-only `sudo -l` on the side channel (no CLI, no lock): the answer
  // is what the next TUN connect will run into, and it lands as sudoRule
  // through applyJob. Never asked while the CLI is missing — there is
  // nothing to start its service for yet.
  function checkSudoRule() {
    if (!installed) return
    sideEnqueue(["sudo-check"], "sudoCheck", false)
  }

  // Asked once, when the CLI first turns up: the answer cannot change while
  // the binary stays put, and a missing one has no path to report.
  function checkCliPath() {
    if (!installed) return
    sideEnqueue(["cli-path"], "cliPath", false)
  }

  // Where the hero's sudo notice sends the user: the README's own account
  // of the rule, for whoever wants passwordless connects. Nothing in this
  // plugin runs as root, so the rule is the user's to install.
  function openSudoHelp() {
    Qt.openUrlExternally(Model.README_URL)
  }

  // A snapshot that runs next: ahead of every queued job (a `locations`
  // refresh alone can take 24 s) but after the running one, which is never
  // interrupted. Only this read-only status check jumps the queue, so user
  // actions keep their order, and one it jumps (a Disconnect, say) is still
  // judged as requested — settleStatus reads the pending toggle. Not skipped
  // for a snapshot already running: that one may have asked the CLI before
  // the drop.
  function refreshNow() {
    _queue = Model.queueFront(_queue, { args: ["snapshot"], verb: "snapshot", mutate: false, stdin: null })
    pump()
  }

  // One look at tunnel.log's tail, TUNNEL_SCAN_DELAY_MS after the first
  // change: a burst of lines is one look. Not restarted by later changes, so
  // a chatty log can't postpone it; a change during a look gets its own.
  function scheduleLogScan() {
    if (watchingTunnelLog && !tunnelLogScanDelay.running) tunnelLogScanDelay.start()
  }

  // `tail -c` rather than FileView's own content: reading the whole log
  // (~1.4 MB and never rotated) on every change is exactly what the watch
  // must not do. The path is an argument, never shell text.
  // When the last look at the tail actually started (epoch ms, 0 = none
  // since the watch was armed). Only rearmTunnelLog's safety-net look reads
  // it; the watch's own scans are never rationed, they just reset it.
  property real _logScanAt: 0

  function scanTunnelLog() {
    if (!watchingTunnelLog) return
    if (tunnelLogTail.running) { tunnelLogTail.again = true; return }
    _logScanAt = Date.now()
    tunnelLogTail.output = ""
    tunnelLogTail.command = ["tail", "-c", String(Model.TUNNEL_TAIL_BYTES), tunnelLogPath]
    tunnelLogTail.running = true
  }

  function applyTunnelLog(text) {
    if (!watchingTunnelLog) return
    var scan = Model.scanTunnelLog(text, _logSeen)
    _logSeen = scan.seen
    if (scan.latest !== "") _logLatest = scan.latest
    var action = Model.tunnelLogAction(scan, _lossBase)
    if (action === "refresh") refresh()
    // Started once per episode, not restarted: RECOVERING after
    // WAITING_RECOVERY must not push the confirm further out.
    else if (action === "confirm" && !tunnelLogConfirm.running) tunnelLogConfirm.start()
  }

  // Rebuilds the file watch after each snapshot that says connected (so at
  // least once per poll while up) and takes a look. FileView already follows
  // the file through a replace or re-create (it watches the directory too);
  // this covers what it can't, like the data directory itself being
  // re-created, and a write that lands while the watch is rebuilt.
  function rearmTunnelLog() {
    if (!watchingTunnelLog) return
    _logRearming = true
    _logRearming = false
    // Rebuilding the watch above costs nothing and happens every time. The
    // look, though, is a `tail -c 65536` spawn, and all it covers is a write
    // landing in the instant the watch was down — the watch reports the rest
    // as it happens — so it is rationed (Model.logScanDue). Anything the
    // FileView itself triggers goes straight to scheduleLogScan, untouched.
    if (Model.logScanDue(_logScanAt, Date.now(), Model.LOG_SCAN_TTL_MS)) scheduleLogScan()
  }

  // Flips the locateHome setting. Turning it off deletes the cached real
  // location right away (no CLI call, no network — agvpn.py's `home forget`
  // just unlinks home.json) and forgets it in memory too, so the map falls
  // straight back to homePoint's time-zone estimate instead of showing a
  // location that can no longer be refreshed.
  function setLocateHome(on) {
    var v = on === true
    persist({ locateHome: v })
    if (!v) {
      home = null
      homeStale = true
      sideEnqueue(["home", "forget"], "home", true)
    }
  }

  // When applyProcs last landed a list (epoch ms, 0 = never).
  property real _procsAt: 0
  function refreshProcs() {
    // Every caller is an autosuggest field taking focus, so this is asked for
    // far more often than the answer changes — see Model.procsFresh.
    if (Model.procsFresh(_procsAt, Date.now(), Model.PROCS_TTL_MS)) return
    sideEnqueue(["procs"], "procs", false)
  }

  // --- the lock-free side channel ---------------------------------------------
  // `procs`, `home cached` and `home forget` never reach agvpn.py's run_cli
  // (the CLI lock lives there and nowhere else), so nothing about them can
  // make adguardvpn-cli overlap itself — yet they queued with everything
  // that does, which meant focusing the kill-switch field could sit behind an
  // 84-second connect. They get their own Process. Every CLI-backed verb
  // still shares the one serialized queue above, unchanged.
  //
  // `mutate` marks the one write here (`home forget`), whose failure must
  // surface as an action error just as it did on the main queue.
  property var _sideQueue: []

  function sideEnqueue(args, verb, mutate) {
    // Reads dedupe against an identical job already running or waiting; the
    // write never does, so turning locateHome off always reaches the helper.
    if (mutate !== true) {
      if (sideProcess.running && sideProcess.verb === verb && !sideProcess.mutate) return
      for (var i = 0; i < _sideQueue.length; i++) if (_sideQueue[i].verb === verb && !_sideQueue[i].mutate) return
    }
    _sideQueue = _sideQueue.concat([{ args: args, verb: verb, mutate: mutate === true }])
    sidePump()
  }

  function sidePump() {
    if (sideProcess.running || _sideQueue.length === 0) return
    var next = _sideQueue[0]
    // home.json is written by the CLI-serialized `home` lookup too, and the
    // single queue is what used to order these against it: a cache read must
    // not answer with a location a lookup has already replaced, and a forget
    // must not be overtaken by a lookup that writes the file back. So a home
    // job here waits for any `home` job on the main queue (jobProcess.onExited
    // pumps this channel again). Named the other way round — the jobs that
    // wait, not the ones that don't — so that a side verb added later, which
    // by definition touches nothing the CLI queue writes, cannot be forgotten
    // into waiting on a lookup it has nothing to do with.
    if ((next.verb === "home" || next.verb === "homeCache") && ((jobProcess.running && jobProcess.verb === "home") || queued("home"))) return
    _sideQueue = _sideQueue.slice(1)
    sideProcess.verb = next.verb
    sideProcess.mutate = next.mutate === true
    sideProcess.output = ""
    sideProcess.command = helper(next.args)
    sideProcess.running = true
    sideWatchdog.interval = Model.watchdogMs(next.args[0])
    sideWatchdog.restart()
  }

  // Pausing takes the domain out of the CLI list but keeps it in our own
  // paused list (per mode), so resume can put it back.
  // Domains are case-insensitive: exclusionRows always shows them lowercase
  // (Model.mergeExclusions/cleanDomains), but exclusions.domains holds
  // whatever case the CLI itself returned for each one. Removing a domain
  // from the CLI's list needs that exact stored spelling — Model.
  // findExclusionDomain does the case-insensitive lookup.
  function setExclusionPaused(domain, paused) {
    var d = String(domain || "").trim().toLowerCase()
    if (d === "") return
    clearError()
    persist({ pausedExclusions: Model.setPaused(pausedExclusions, exclusions.mode, d, paused) })
    if (paused) {
      var stored = Model.findExclusionDomain(exclusions.domains, d)
      if (stored !== null) enqueue(["exclusions", "remove", stored], "exclusions", false, true)
    } else {
      enqueue(["exclusions", "add", d], "exclusions", false, true)
    }
  }

  function forgetExclusion(domain) {
    var d = String(domain || "").trim().toLowerCase()
    if (d === "") return
    clearError()
    if (Model.setPaused(pausedExclusions, exclusions.mode, d, false)[exclusions.mode].length !== (pausedExclusions[exclusions.mode] || []).length)
      persist({ pausedExclusions: Model.setPaused(pausedExclusions, exclusions.mode, d, false) })
    var stored = Model.findExclusionDomain(exclusions.domains, d)
    if (stored !== null) enqueue(["exclusions", "remove", stored], "exclusions", false, true)
  }

  function refreshConfig() { enqueue(["config", "show"], "config", true) }

  property bool _notifyUpdate: false
  function checkUpdate(notifyIfAvailable) {
    _notifyUpdate = notifyIfAvailable === true
    enqueue(["update-check"], "update", true)
  }

  function runUpdate() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Model.cliCommand(root.cliPath, "update")])
    actionStatus = "Updating from the terminal"
  }

  // Set by a config mutation that would only take effect on the next
  // connect; the "Applies on the next connect" hint fires from the job's
  // own success (onExited) rather than here, so a failed set never claims it.
  property bool _configHintPending: false

  function setConfig(key, value) {
    var k = String(key)
    clearError()
    _configHintPending = connected && ["mode", "protocol", "postQuantum", "dns", "changeSystemDns"].indexOf(k) !== -1
    // Model.configJob keeps a secret (the SOCKS password) out of args, where
    // any local user could read it in ps, and hands it over as the job's
    // stdin instead.
    var job = Model.configJob(k, value)
    enqueue(job.args, "config", false, true, job.stdin)
  }

  function notify(title, body, urgency) {
    Quickshell.execDetached(["omarchy", "notification", "send", "--app-name", "Aegis", "-g", "󰒘",
      "-u", urgency || "normal", String(title), String(body || "")])
  }

  // --- actions ------------------------------------------------------------------
  // `inTerminal`: run it in a terminal whatever the state says — for a
  // connect the helper just ran that sudo turned away (retryInTerminal),
  // where the state that said "no terminal needed" was the one that lied.
  function connectTo(cliName, city, inTerminal) {
    var target = String(cliName || "")
    if (target === "" || !installed) return
    _desired = 1
    pendingLocation = String(city || target)
    clearError()
    // The user (or startup auto-connect) is acting on the tunnel again — a
    // home lookup held since an earlier unexpected drop no longer needs to
    // wait; see dropHold / Model.mayLocateHome.
    dropHold = false
    if (inTerminal === true || Model.connectNeedsTerminal(sudoRule, nextMode, vpnState)) { connectInTerminal(target); return }
    enqueue(["connect", target], "connect")
  }

  // A TUN connect without the sudo rule: the CLI's own `connect`, in a
  // floating terminal where sudo can ask for the password (the helper has
  // no terminal to offer it). The same poll as login's watches the tunnel
  // come up — the terminal takes focus and closes the panel, so nothing
  // else would notice — and the snapshot that sees it connected clears
  // pendingLocation, as after any connect.
  function connectInTerminal(cliName) {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Model.connectCommand(root.cliPath, cliName)])
    actionStatus = "Enter your password in the terminal"
    loginPoll.waitFor = "connect"
    loginPoll.ticks = 0
    loginPoll.start()
  }

  // A connect the helper ran that sudo turned away for a password (the
  // probe had not answered yet, or was wrong): the same connect again, by
  // city, which now goes to a terminal because noteError has just settled
  // sudoRule as missing.
  function retryInTerminal(city) {
    var loc = Model.findLocation(locations, city)
    if (loc) connectTo(loc.cliName, loc.city, true)
  }

  function down() {
    if (!installed) return
    _desired = 0
    pendingLocation = ""
    clearError()
    dropHold = false
    if (wasConnected) persist({ wasConnected: false })
    enqueue(["disconnect"], "disconnect")
  }

  function toggleVpn() {
    if (active) { down(); return }
    var last = Model.findLocation(locations, lastLocation)
    if (last) connectTo(last.cliName, last.city)
    else if (locations.length > 0) connectTo(locations[0].cliName, locations[0].city)
    // Not tied to any CLI job, so nothing will ever resolve it by itself;
    // errorIntent stays null.
    else { lastError = "No locations loaded yet"; errorCode = "unknown"; errorSource = "action"; errorIntent = null }
  }

  function setExclusionMode(mode) {
    clearError()
    enqueue(["exclusions", "mode", String(mode)], "exclusions", false, true)
  }
  function addExclusion(domain) {
    // Lowercased so the domain lands in the CLI's list in the same case
    // exclusionRows will later display and compare it in.
    var d = String(domain || "").trim().toLowerCase()
    if (d === "") return
    clearError()
    enqueue(["exclusions", "add", d], "exclusions", false, true)
  }
  function removeExclusion(domain) {
    clearError()
    enqueue(["exclusions", "remove", String(domain)], "exclusions", false, true)
  }

  function logout() {
    if (wasConnected) persist({ wasConnected: false })
    dropHold = false
    enqueue(["logout"], "logout")
  }

  // Reconnect at login when the VPN was on the last time the shell ran, or
  // when it died without a clean disconnect (the flag outlives crashes).
  function maybeAutoConnect(state) {
    var ok = Model.shouldAutoConnect({ autoConnect: autoConnect, wasConnected: wasConnected, state: state,
      installed: installed, loggedIn: accountLoaded ? account.loggedIn : true, attempted: autoConnectAttempted,
      needsTerminal: Model.connectNeedsTerminal(sudoRule, nextMode, state) })
    if (!ok) return
    autoConnectAttempted = true
    if (lastLocation === "") return
    var last = Model.findLocation(locations, lastLocation)
    // From here a connect is actually about to run — hold any home lookup
    // until it finishes or fails (see autoConnectPending, cleared in
    // jobProcess.onExited).
    autoConnectPending = true
    connectTo(last ? last.cliName : lastLocation, lastLocation)
  }

  // kind is "drop" or "disconnect" (see Model.tunnelLoss / lossResponse).
  function onTunnelLoss(kind, fromLocation) {
    var response = Model.lossResponse(kind, { location: fromLocation, killSwitch: killSwitch,
      killOnDisconnect: killOnDisconnect, apps: killApps })
    if (!response) return
    if (response.kill.length > 0) {
      killProcess.command = helper(["kill"].concat(response.kill))
      killProcess.running = true
    }
    notify(response.title, response.body, response.urgency)
  }

  function login() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Model.cliCommand(root.cliPath, "login")])
    actionStatus = "Log in from the terminal"
    loginPoll.waitFor = "login"
    loginPoll.ticks = 0
    loginPoll.start()
  }

  // AdGuard's install instructions in the user's browser
  // (Model.CLI_INSTALL_URL). The plugin runs no installer: the user follows
  // the guide in a terminal of their own. The same poll as login's watches
  // for the CLI: the snapshot stops answering cli_missing once the binary
  // is there.
  function openInstallGuide() {
    Qt.openUrlExternally(Model.CLI_INSTALL_URL)
    actionStatus = "Install guide opened in your browser"
    loginPoll.waitFor = "install"
    loginPoll.ticks = 0
    loginPoll.start()
  }

  property var _queue: []
  readonly property var _refreshVerbs: ["snapshot", "locations", "account", "exclusions", "home", "homeCache", "config", "update", "procs"]
  readonly property bool busy: jobProcess.running && _refreshVerbs.indexOf(jobProcess.verb) === -1
  readonly property bool refreshing: jobProcess.running && _refreshVerbs.indexOf(jobProcess.verb) !== -1
  readonly property bool updateChecking: (jobProcess.running && jobProcess.verb === "update") || queued("update")

  function queued(verb) {
    for (var i = 0; i < _queue.length; i++) if (_queue[i].verb === verb) return true
    return false
  }

  // `dedupe` jobs (the refreshes) are skipped when the same verb is already
  // running or waiting; actions always queue so each one runs. `mutate`
  // marks a user-initiated write riding a read-only verb ("exclusions",
  // "config"): its failure must reach noteError even though the verb itself
  // is a _refreshVerbs entry — see jobProcess.onExited. `stdin`: a string
  // the helper reads as one line on stdin (a secret, see Model.configJob),
  // or undefined/null for none. It only ever lives in memory: pump moves it
  // off the job onto jobProcess, which drops it once written.
  function enqueue(args, verb, dedupe, mutate, stdin) {
    if (dedupe && ((jobProcess.running && jobProcess.verb === verb) || queued(verb))) return
    // Model.queueAppend folds a connect into a connect already at the tail
    // (last click wins) and appends everything else; the running job is not
    // in the queue, so it is never touched.
    _queue = Model.queueAppend(_queue, { args: args, verb: verb, mutate: mutate === true,
      stdin: typeof stdin === "string" ? stdin : null })
    pump()
  }

  function pump() {
    if (jobProcess.running || _queue.length === 0) return
    var next = _queue[0]
    _queue = _queue.slice(1)
    jobProcess.verb = next.verb
    jobProcess.mutate = next.mutate === true
    jobProcess.output = ""
    jobProcess.stdinPayload = next.stdin !== null ? next.stdin : ""
    // Before `running`: Quickshell shuts a Process's write channel at start
    // when stdinEnabled is false, and write() can't reopen it for that run.
    // (The child still sees no EOF then; the helper only reads stdin for a
    // job that has a payload.)
    jobProcess.stdinEnabled = next.stdin !== null
    next.stdin = null
    jobProcess.command = helper(next.args)
    jobProcess.running = true
    jobWatchdog.stopping = false
    jobWatchdog.interval = Model.watchdogMs(next.args[0])
    jobWatchdog.restart()
  }

  function applyJob(verb, obj, exitCode) {
    if (verb === "snapshot") applySnapshot(obj)
    else if (verb === "locations") applyLocations(obj)
    else if (verb === "account") applyAccount(obj)
    else if (verb === "exclusions") applyExclusions(obj)
    else if (verb === "home") applyHome(obj, false)
    else if (verb === "homeCache") applyHome(obj, true)
    else if (verb === "config") applyConfig(obj)
    else if (verb === "update") applyUpdate(obj, _notifyUpdate)
    else if (verb === "procs") applyProcs(obj)
    else if (verb === "sudoCheck") sudoRule = obj.allowed === true ? "ok" : "missing"
    else if (verb === "cliPath") cliPath = typeof obj.path === "string" ? obj.path : ""
    else if (verb === "connect" || verb === "disconnect") applySnapshot(obj, verb === "disconnect", verb)
    else if (verb === "logout") {
      // Logging out takes the tunnel down on request: an intentional
      // disconnect (kill switch only with killOnDisconnect), never a drop.
      var loss = Model.tunnelLoss(_lossBase, "logged_out", true)
      account = Model.loggedOutAccount()
      vpnState = "logged_out"
      if (loss !== "") onTunnelLoss(loss, location)
    }
  }

  // --- parsing -------------------------------------------------------------------
  function parseJson(text) {
    try {
      var obj = JSON.parse(String(text || ""))
      return obj && typeof obj === "object" ? obj : { ok: false, error: "helper returned no object", code: "parse" }
    } catch (e) {
      return { ok: false, error: "helper output was not JSON", code: "parse" }
    }
  }

  // Resets the standing error and what it was about. Called wherever the
  // user starts a new action (each action owns its own outcome from there)
  // and wherever a snapshot proves an action's error is resolved.
  function clearError() {
    lastError = ""
    errorCode = ""
    errorSource = ""
    errorIntent = null
  }

  // `source`: "action" for a user-initiated connect/disconnect/exclusion/
  // config call, left "" for a routine background outcome (see errorSource).
  // `intent`: what a connect/disconnect action wanted (see errorIntent);
  // only kept when the error actually ends up "action"-sourced, so a sudo
  // warning raised mid-connect never carries one (sudo keeps the old rule).
  function noteError(obj, source, intent) {
    lastError = Model.elideStatus(obj.error || "AdGuard VPN helper failed")
    errorCode = String(obj.code || "unknown")
    errorSource = errorCode === "sudo_password" ? "sudo" : (source || "")
    errorIntent = errorSource === "action" ? (intent || null) : null
    if (errorCode === "cli_missing") installed = false
    if (errorCode === "logged_out") {
      vpnState = "logged_out"
      account = Model.loggedOutAccount()
      accountLoaded = true
    }
    if (errorCode === "sudo_password") {
      lastError = "sudo needs a password to start the VPN service"
      sudoRule = "missing"
    }
  }

  // `requested`: the status came back from a disconnect the user asked for.
  // `verb`: the job this snapshot came from ("connect"/"disconnect"), left
  // undefined for a plain status poll.
  function applySnapshot(obj, requested, verb) {
    if (obj.ok === false) { noteError(obj); return }
    installed = true
    var snap = Model.normalizeSnapshot(obj)
    // Status the helper could not parse proves nothing about the tunnel: keep
    // the last known state instead of running the drop path, the kill switch
    // or startup auto-connect on it. A standing action/sudo error is not
    // papered over by this generic message either (Model.errorProtected).
    if (snap.state === "unknown") {
      // ...and an action that succeeded is not an error at all: agvpn.py
      // answers a connect/disconnect whose own follow-up `status` failed
      // with a snapshot-shaped state "unknown", so the tunnel did change,
      // only the readback didn't. Keeping the last state is right; calling
      // it unrecognised output would put a false error under a connect the
      // user just watched work. delayedRefresh (Model.needsFollowUpRefresh
      // keeps it for exactly this case) fetches the real state shortly.
      var fromAction = verb === "connect" || verb === "disconnect"
      if (!fromAction && !Model.errorProtected(errorSource)) { lastError = "Unrecognised adguardvpn-cli status output"; errorCode = "parse"; errorSource = ""; errorIntent = null }
      return
    }
    var prevLocation = location
    // Judged before the pending toggle settles; see Model.settleStatus. From
    // the last settled state, not vpnState: a "connecting" status mid-
    // recovery must not hide a drop that follows it (Model.lossBase).
    var step = Model.settleStatus({ prevState: _lossBase, nextState: snap.state, desired: _desired,
      requested: requested === true, wasConnected: wasConnected })
    vpnState = snap.state
    location = snap.location
    iso = snap.iso
    iface = snap.iface
    mode = snap.mode
    listen = snap.listen || ""
    endpoint = snap.endpoint
    sinceEpoch = snap.sinceEpoch
    // Reality caught up with the pending toggle.
    _desired = step.desired
    if (snap.state === "connected") { pendingLocation = ""; rearmTunnelLog() }
    if (snap.state === "logged_out") {
      account = Model.loggedOutAccount()
      accountLoaded = true
    }
    // The other direction: this snapshot proves a login the cached account
    // predates, so go and get the real one. See Model.accountStale — the
    // account tab read "Not signed in" over a full location list until the
    // user happened to switch to it. `dedupe` keeps repeat polls to one call.
    else if (Model.accountStale(snap.state, accountLoaded, account.loggedIn)) refreshAccount()
    // Already zero: assigning a fresh { 0, 0 } would signal the bar's rate
    // label and every binding on it for no change at all.
    if (snap.state !== "connected" && (rates.down !== 0 || rates.up !== 0)) rates = { down: 0, up: 0 }
    // The graph's history goes the same way, and for the same reason: an
    // empty array assigned over an empty one would still signal the canvas.
    if (snap.state !== "connected" && trafficHistory.length > 0) trafficHistory = []
    // An unexpected drop holds off any home lookup until the user acts
    // again (dropHold, cleared by connectTo/down/logout) — right after a
    // drop is exactly when the user expects to be protected, not queried.
    if (step.loss === "drop") dropHold = true
    // step.wasConnected is what this very snapshot just decided (non-null
    // only on an actual transition); the wasConnected property itself isn't
    // updated until the persist() below runs, so using it here directly
    // would gate on the previous snapshot's value — see maybeRefreshHome.
    var wasConnectedNow = step.wasConnected !== null ? step.wasConnected : wasConnected
    if (homeStale) maybeRefreshHome(wasConnectedNow)
    // A background/routine status refresh clears only errors it is entitled
    // to supersede; an action's own error otherwise stands until the user
    // starts a new action (see connectTo/down/setConfig/exclusion mutators)
    // — unless this very snapshot proves what that action wanted actually
    // happened (the CLI finished after a watchdog timeout, auto-connect's
    // network blip cleared up, ...), which resolves it too.
    if (!Model.errorProtected(errorSource) || Model.errorResolved(errorIntent, snap)) clearError()
    if (step.wasConnected !== null) persist({ wasConnected: step.wasConnected })
    if (step.loss !== "") onTunnelLoss(step.loss, prevLocation)
    if (!startupSettled && snap.state !== "connecting") {
      startupSettled = true
      maybeAutoConnect(snap.state)
      // Now it's clear whether the VPN will stay off (auto-connect off,
      // not due, failed already, or no last location) or is about to come
      // back up (autoConnectPending) — either way Model.mayLocateHome knows
      // what to do with it.
      maybeRefreshHome(wasConnectedNow)
    }
  }

  function applyProcs(obj) {
    if (obj.ok === false) return
    var list = Model.toList(obj.procs)
    // Same list, same object: assigning would signal anyway and rebuild the
    // kill-switch suggestions. See Model.sameProcs.
    if (!Model.sameProcs(procs, list)) procs = list
    // Only a successful answer starts the TTL, so a failed one retries.
    _procsAt = Date.now()
  }

  function applyConfig(obj) {
    if (obj.ok === false) { noteError(obj); return }
    var nextConfig = Model.normalizeConfig(obj)
    if (!Model.sameConfig(config, nextConfig)) config = nextConfig
    configLoaded = true
  }

  function applyUpdate(obj, notifyIfAvailable) {
    // A failed/indeterminate check (agvpn.py returns ok: false rather than
    // guessing upToDate) never reaches here — see jobProcess.onExited, which
    // keeps it quiet (no noteError) and schedules a backoff retry instead.
    // So reaching this function at all means the check actually succeeded:
    // safe to persist lastUpdateCheck and clear any pending retry.
    if (obj.ok === false) { noteError(obj); return }
    var info = Model.normalizeUpdate(obj)
    info.checkedAt = Date.now()
    // An unchanged answer keeps the object already on screen; checkedAt is
    // only ever read as "has a check succeeded" (Model.sameUpdate).
    if (!Model.sameUpdate(update, info)) update = info
    root._updateRetryAt = 0
    persist({ lastUpdateCheck: Math.floor(Date.now() / 1000) })
    if (notifyIfAvailable && !info.upToDate && info.latest)
      notify("AdGuard VPN update", info.latest + " is available")
  }

  function applyLocations(obj) {
    if (obj.ok === false) { noteError(obj); return }
    var list = Model.normalizeLocations(obj)
    // An identical list would still signal and rebuild every list delegate
    // 1-3 s after each panel open; see Model.sameLocations.
    if (!Model.sameLocations(locations, list)) locations = list
    // Stamped even for an empty answer; locationsFresh's own count check is
    // what keeps an empty list from being treated as fresh.
    _locationsAt = Date.now()
  }

  function applyAccount(obj) {
    if (obj.ok === false) { noteError(obj); return }
    var nextAccount = Model.normalizeAccount(obj)
    if (!Model.sameAccount(account, nextAccount)) account = nextAccount
    accountLoaded = true
    if (account.loggedIn && vpnState === "logged_out") vpnState = "disconnected"
    if (!account.loggedIn) vpnState = "logged_out"
  }

  function applyExclusions(obj) {
    if (obj.ok === false) { noteError(obj); return }
    exclusions = Model.normalizeExclusions(obj)
  }

  // `fromCache`: whether this answer came from the cache-only job
  // (refreshHomeCache, agvpn.py's `home cached`) rather than a real lookup
  // (refreshHome/maybeRefreshHome, `home`). Model.shouldApplyHomeJob refuses
  // a cache-only miss that would blow away a home a real lookup already set
  // — see its own comment; every other answer (a cache hit, or anything
  // from a real lookup) is applied as before.
  function applyHome(obj, fromCache) {
    if (obj.ok === false) return
    var incoming = obj.home && typeof obj.home === "object" ? obj.home : null
    if (!Model.shouldApplyHomeJob(home, fromCache === true, incoming)) return
    home = incoming
    homeStale = obj.stale === true || home === null
  }

  property var _prev: null
  function applyCounters(text) {
    var parts = String(text || "").trim().split(/\s+/)
    if (parts.length < 2) return
    var next = { rx: Number(parts[0]), tx: Number(parts[1]), at: Date.now() }
    if (!isFinite(next.rx) || !isFinite(next.tx)) return
    // Only a real pair of reads produces a rate, and only a rate is worth a
    // column: the first read after the sampler starts has nothing to compare
    // against and would push a flat zero the graph would have to draw.
    if (_prev) {
      rates = Model.rateFrom(_prev, next, next.at - _prev.at)
      trafficHistory = Model.pushSample(trafficHistory, rates, Model.TRAFFIC_CAP)
    }
    _prev = next
    rx = next.rx
    tx = next.tx
  }

  // --- timers -------------------------------------------------------------------
  Timer {
    id: refreshTimer
    // Changing a Timer's interval restarts its countdown, so every input here
    // is deliberately coarse: a panel open/close, a connect or drop, the
    // tunnel.log watch arming, or a bar-mode change — never anything that
    // moves on its own. See Model.pollIntervalMs for what each one means.
    interval: Model.pollIntervalMs({ intervalSec: root.refreshIntervalSec, panelOpen: root.panelOpen,
      connected: root.connected, watchingTunnelLog: root.watchingTunnelLog, barMode: root.barMode,
      installed: root.installed })
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refresh()
      // A failed background update check backs off instead of persisting
      // lastUpdateCheck (see applyUpdate/jobProcess.onExited); retry it here
      // once the backoff has elapsed, still gated by updateCheckDue so it
      // never fires more than once per successful 24h cycle either.
      if (root._updateRetryAt !== 0 && Date.now() >= root._updateRetryAt
          && !root.updateChecking && Model.updateCheckDue(root.lastUpdateCheck, Date.now()))
        root.checkUpdate(true)
    }
  }

  Timer {
    // Poll quickly after the shell starts until the CLI answers, then stop.
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    // Stops the moment the helper reports cli_missing: there is nothing for
    // the ramp to catch up with then, and it would otherwise spend all 15
    // ticks re-asking a question already answered. (The imperative stop
    // below replaces this binding when the ramp finishes normally, which is
    // fine — it never starts again either way.)
    running: root.installed
    onTriggered: {
      ticks += 1
      if (root.vpnState !== "unknown" || ticks >= 15) { startupRamp.running = false; return }
      root.refresh()
    }
  }

  Timer {
    id: delayedRefresh
    interval: 600
    onTriggered: root.refresh()
  }

  Timer {
    id: tunnelLogScanDelay
    interval: Model.TUNNEL_SCAN_DELAY_MS
    onTriggered: root.scanTunnelLog()
  }

  Timer {
    // The confirm step (Model.tunnelLogAction's "confirm"): by now a switch
    // or a recovery has logged CONNECTED; if not, the snapshot settles it.
    id: tunnelLogConfirm
    interval: Model.TUNNEL_CONFIRM_MS
    onTriggered: if (Model.confirmDrop(root._logLatest, root._lossBase)) root.refreshNow()
  }

  Timer {
    id: jobWatchdog
    // Last resort. agvpn.py answers within its own per-verb budget (lock
    // wait and every sub-call timeout included) and Model.watchdogMs is that
    // budget plus slack, so this only fires when the helper itself hangs.
    // First `running = false` (SIGTERM): the helper stops and reaps its CLI
    // child, then answers a timeout that onExited handles like any other
    // failure, errorIntent included. If it still hasn't exited
    // WATCHDOG_KILL_MS later, SIGKILL — a CLI child it leaves behind holds
    // the CLI lock itself, so the next job still can't overlap it.
    property bool stopping: false
    interval: Model.watchdogMs("")
    onTriggered: {
      if (!jobProcess.running) return
      if (!stopping) {
        stopping = true
        jobProcess.running = false
        interval = Model.WATCHDOG_KILL_MS
        restart()
        return
      }
      jobProcess.signal(9)
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: rateTimer
    // A sample a second for as long as the tunnel is up, whether or not
    // anything is looking: every sample is a column of the traffic graph,
    // and the graph is meant to have its history the moment the tab opens,
    // not to start from empty because the panel was closed. One cadence
    // throughout, so a column is always one second — a slower one while
    // unwatched would squeeze that history into columns of different widths.
    // Two sysfs reads through `cat` a second is the whole cost.
    interval: 1000
    repeat: true
    running: root.connected && root.iface !== ""
    triggeredOnStart: true
    onTriggered: {
      if (countersProcess.running) return
      var base = "/sys/class/net/" + root.iface + "/statistics/"
      countersProcess.command = ["cat", base + "rx_bytes", base + "tx_bytes"]
      countersProcess.running = true
    }
    onRunningChanged: if (!running) root._prev = null
  }

  Timer {
    id: loginPoll
    property int ticks: 0
    // "login": waiting for the account (refreshAccount); "install": waiting
    // for the CLI itself (a plain snapshot, which is what says cli_missing);
    // "connect": waiting for the tunnel a terminal connect is bringing up.
    property string waitFor: "login"
    // Fast while the user is plausibly still typing in the login terminal,
    // then slower (Model.loginPollIntervalMs). The interval change restarts
    // the countdown, which is what we want: the new cadence runs from the
    // tick that just happened.
    interval: Model.loginPollIntervalMs(ticks)
    repeat: true
    onTriggered: {
      ticks += 1
      if (waitFor === "install") {
        root.refresh()
        if (root.installed || ticks >= Model.LOGIN_POLL_MAX_TICKS) { loginPoll.stop(); if (root.installed) root.refreshAll(true) }
        return
      }
      if (waitFor === "connect") {
        root.refresh()
        if (root.connected || ticks >= Model.LOGIN_POLL_MAX_TICKS) {
          loginPoll.stop()
          // Gave up: the terminal was closed or the password never came.
          if (!root.connected) { root._desired = -1; root.pendingLocation = "" }
        }
        return
      }
      root.refreshAccount()
      if (root.account.loggedIn || ticks >= Model.LOGIN_POLL_MAX_TICKS) { loginPoll.stop(); root.refresh() }
    }
  }

  onPanelOpenChanged: {
    if (panelOpen) { refreshAll(); return }
    // The poll stays. Everything it waits for — the install the user does
    // from AdGuard's guide, `adguardvpn-cli login`, a connect typing its
    // sudo password — happens in a window that takes focus (a browser, a
    // terminal), so the panel closes the moment it starts, and none is
    // noticed by
    // the ordinary poll: a missing CLI slows that to POLL_MISSING_MS, and a
    // finished login never reaches it at all, because it only ever fetches
    // a snapshot. Stopping here left the panel offering Install ten minutes
    // after the install, and "Not signed in" after the login. It is bounded
    // by LOGIN_POLL_MAX_TICKS on its own.
  }
  // A CLI that has just appeared (the install the setup prompt points to, a
  // package manager) gets the sudo probe the missing one was spared.
  onInstalledChanged: {
    if (installed && sudoRule === "unknown") checkSudoRule()
    if (installed && cliPath === "") checkCliPath()
  }
  // Every path that sets vpnState (snapshots, logout, noteError, account)
  // moves the loss base with it.
  onVpnStateChanged: _lossBase = Model.lossBase(_lossBase, vpnState)
  // Starting the watch primes a fresh look (what the log already holds is
  // history); stopping it forgets the log's position and any pending confirm.
  onWatchingTunnelLogChanged: {
    _logSeen = null
    if (watchingTunnelLog) { scheduleLogScan(); return }
    _logLatest = ""
    tunnelLogScanDelay.stop()
    tunnelLogConfirm.stop()
  }
  onActionStatusChanged: if (actionStatus !== "") actionStatusTimer.restart()
  Component.onCompleted: {
    tzProcess.running = true
    // First in the queue, ahead of everything else here: the bar icon,
    // startupSettled, startup auto-connect and the tunnel.log watch all wait
    // on the first status, and a `locations` refresh alone can hold the one
    // serialized queue for 24 s. refreshTimer's own triggeredOnStart tick
    // costs nothing extra — enqueue's dedupe folds it into this job.
    refresh()
    // A no-op here (startupSettled is still false) — kept so every
    // refreshHome() call site is gated the same way; the real first lookup
    // fires from applySnapshot once startup settles and auto-connect's fate
    // is known. See Model.mayLocateHome.
    maybeRefreshHome()
    // Unlike the lookup above, reading the cache needs no network and
    // reveals nothing, so it runs right away regardless of vpnState (still
    // "unknown" here) — this is what fixes home staying null after a
    // restart while connected, since the cached location was always there
    // on disk. Skipped only when locateHome is off: `home forget` already
    // deleted the cache then, so there would be nothing to read anyway.
    if (locateHome) refreshHomeCache()
    refreshLocations()
    if (Model.updateCheckDue(lastUpdateCheck, Date.now())) updateCheckDelay.start()
  }

  Timer {
    id: updateCheckDelay
    interval: 20000
    onTriggered: root.checkUpdate(true)
  }

  // --- processes ------------------------------------------------------------------
  Process {
    id: tzProcess
    command: ["sh", "-c", "echo \"${TZ:-$(readlink -f /etc/localtime 2>/dev/null)}\""]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.timezone = String(text || "").trim() }
  }

  Process {
    id: killProcess
  }

  // A change trigger only. With preload: false, FileView reads a file only
  // when text()/data() is called (Quickshell 0.3 fileview.cpp updatePath/
  // text), and nothing here calls them: a 64 MB probe file under this exact
  // setup saw no reads across appends, an atomic replace and a re-create.
  // The watch covers the file and its directory, so a log that doesn't exist
  // yet (never connected) fires once it is created. A burst of appends
  // arrives as one or a few fileChanged signals; scheduleLogScan folds them.
  FileView {
    id: tunnelLogWatch
    path: root.tunnelLogPath
    preload: false
    printErrors: false
    watchChanges: root.watchingTunnelLog && !root._logRearming
    onFileChanged: root.scheduleLogScan()
  }

  Process {
    id: tunnelLogTail
    property string output: ""
    // A change noticed while this look was running gets a look of its own.
    property bool again: false
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: tunnelLogTail.output = text }
    onExited: function(exitCode) {
      var text = tunnelLogTail.output
      tunnelLogTail.output = ""
      // A failed read (no log yet, not readable) says nothing about the
      // tunnel: the directory watch fires once the file appears, and the
      // poll carries on either way.
      if (exitCode === 0) root.applyTunnelLog(text)
      if (tunnelLogTail.again) { tunnelLogTail.again = false; root.scheduleLogScan() }
    }
  }

  Timer {
    id: sideWatchdog
    // The same last resort jobWatchdog is, without its SIGTERM-then-SIGKILL
    // dance: no verb on this channel starts an adguardvpn-cli child, so
    // there is no CLI lock a leftover child could keep holding — stopping
    // the helper is the whole cleanup. Interval is set per job in sidePump.
    interval: Model.watchdogMs("procs")
    onTriggered: if (sideProcess.running) sideProcess.running = false
  }

  Process {
    id: sideProcess
    property string verb: ""
    property bool mutate: false
    property string output: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: sideProcess.output = text }
    onExited: function(exitCode) {
      sideWatchdog.stop()
      var verb = sideProcess.verb
      var mutate = sideProcess.mutate === true
      var obj = root.parseJson(sideProcess.output)
      sideProcess.output = ""
      // Same parse and apply path as the main queue's jobs.
      if (obj.ok !== false && exitCode === 0) root.applyJob(verb, obj, exitCode)
      // A failed background read stays as quiet as it was on the main queue;
      // the one write here (`home forget`) still reports, as it did there.
      else if (mutate) root.noteError(obj.ok === false ? obj
        : { error: "AdGuard VPN helper exited " + exitCode, code: "unknown" }, "action", null)
      root.sidePump()
    }
  }

  Process {
    id: countersProcess
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyCounters(text) }
  }

  Process {
    id: jobProcess
    property string verb: ""
    property bool mutate: false
    property string output: ""
    // The running job's stdin line (see enqueue); "" once written or gone.
    property string stdinPayload: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: jobProcess.output = text }
    onStarted: {
      if (!stdinEnabled) return
      write(stdinPayload + "\n")
      stdinPayload = ""
      // Closes the write channel once the line is flushed, so the helper
      // also sees EOF. It doesn't rely on that: it stops at the newline and
      // has its own read timeout.
      stdinEnabled = false
    }
    // A job that never started (a failed start emits no `exited`) must not
    // keep its secret around either. `running` is already true again here
    // when onExited's pump started the next job, so that job's is kept.
    onRunningChanged: if (!running) { stdinPayload = ""; stdinEnabled = false }
    onExited: function(exitCode) {
      jobWatchdog.stop()
      jobProcess.stdinPayload = ""
      jobProcess.stdinEnabled = false
      var verb = jobProcess.verb
      var mutate = jobProcess.mutate === true
      var obj = root.parseJson(jobProcess.output)
      // Stopped by jobWatchdog: a helper that answered its SIGTERM already
      // says "timeout", one that had to be SIGKILLed printed nothing.
      if (jobWatchdog.stopping && obj.ok === false && obj.code === "parse")
        obj = { ok: false, error: "Timed out waiting for adguardvpn-cli", code: "timeout" }
      jobWatchdog.stopping = false
      jobProcess.output = ""
      // Before the split below, because a failure proves the CLI is there
      // just as well as a success: "Not logged in" is the only thing a
      // freshly installed CLI says, and everything that fails goes to
      // noteError without ever reaching applyJob. See Model.provesInstalled.
      // (sideProcess needs none of this: its verbs never run the binary.)
      if (Model.provesInstalled(verb, obj)) root.installed = true
      var ok = obj.ok !== false && exitCode === 0
      var isAction = root._refreshVerbs.indexOf(verb) === -1
      // Whatever connect job this was (auto-connect's own or a manual one
      // queued behind it — the queue never runs two at once), it has now
      // finished or failed either way: a home lookup held for
      // autoConnectPending is free to run again on the next snapshot.
      var wasAuto = root.autoConnectPending
      if (verb === "connect") root.autoConnectPending = false
      // A tunnel that came up went through sudo without a prompt: whatever
      // the probe said (or has not said yet), the rule is in place.
      if (verb === "connect" && ok && Model.normalizeSnapshot(obj).state === "connected") root.sudoRule = "ok"
      if (!ok) {
        // Captured before the pendingLocation reset below, so a later
        // snapshot can tell whether connect/disconnect got there anyway.
        var intent = verb === "connect" ? { verb: "connect", target: root.pendingLocation }
          : (verb === "disconnect" ? { verb: "disconnect" } : null)
        // `mutate`: an exclusions/config write riding the read-only verb —
        // its failure must surface too, unlike a plain background refresh.
        if (isAction || mutate || verb === "snapshot" || verb === "locations" || verb === "account")
          root.noteError(obj.ok === false ? obj : { error: "AdGuard VPN helper exited " + exitCode, code: "unknown" },
            (isAction || mutate) ? "action" : "", intent)
        if (isAction) { root._desired = -1; root.pendingLocation = "" }
        // A connect that sudo turned away for a password goes to a terminal
        // that can answer it (Model.connectNeedsTerminal) — unless it was
        // startup auto-connect, which never opens anything on its own.
        if (verb === "connect" && obj.code === "sudo_password" && !wasAuto) root.retryInTerminal(intent.target)
        if (verb === "config" && mutate) root._configHintPending = false
        // A failed/indeterminate background update check stays quiet (no
        // noteError above, no lastUpdateCheck persisted in applyUpdate,
        // which is never reached) but must still retry sooner than the next
        // 24h-due check, without hammering the CLI — see refreshTimer.
        if (verb === "update") root._updateRetryAt = Date.now() + 30 * 60 * 1000
      } else {
        root.applyJob(verb, obj, exitCode)
        // The "Applies on the next connect" hint only fires once the set
        // actually succeeded, never optimistically from setConfig itself.
        if (verb === "config" && mutate && root._configHintPending) {
          root.actionStatus = "Applies on the next connect"
          root._configHintPending = false
        }
      }
      if (isAction) {
        root.actionFinished(verb, ok)
        // connect and disconnect answer with a whole snapshot of their own,
        // so one that succeeded with a definite state has already put
        // everything this poll would fetch on screen — see
        // Model.needsFollowUpRefresh. Failures, an unreadable follow-up
        // status and logout still get it.
        if (Model.needsFollowUpRefresh(verb, ok, ok ? Model.normalizeSnapshot(obj).state : ""))
          delayedRefresh.restart()
      }
      root.pump()
      // A home job on the side channel waits while a `home` lookup is in
      // flight here (see sidePump); this is where that wait ends.
      root.sidePump()
    }
  }
}
