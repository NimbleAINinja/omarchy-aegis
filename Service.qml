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

  // Optimistic switch state: -1 follows reality, 0/1 while an action is in flight.
  property int _desired: -1
  readonly property bool connected: vpnState === "connected"
  readonly property bool active: _desired === -1 ? (vpnState === "connected" || vpnState === "connecting") : _desired === 1
  readonly property string linkState: vpnState === "connected" ? "connected"
    : (vpnState === "connecting" || pendingLocation !== "" ? "connecting" : "none")
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

  property var procs: []
  readonly property var pausedExclusions: Model.normalizePaused(setting("pausedExclusions", null))
  readonly property var exclusionRows: Model.mergeExclusions(exclusions.domains, pausedExclusions[exclusions.mode] || [])
  property var config: Model.normalizeConfig(null)
  property bool configLoaded: false
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
  function refreshLocations() { enqueue(["locations"], "locations", true) }
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
  function refreshHomeCache() { enqueue(["home", "cached"], "homeCache", true) }

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

  function refreshAll() {
    refresh()
    refreshLocations()
    if (!accountLoaded) refreshAccount()
    maybeRefreshHome()
    // Whenever the panel opens (refreshAll's only real caller, plus the "r"
    // shortcut/middle-click/IPC refresh) with locateHome on and no home
    // loaded yet — a shell restart while connected leaves it null, since
    // maybeRefreshHome above is a no-op until the tunnel is down by choice
    // — the cache read can only help and never leaks anything, so it always
    // runs rather than waiting on that.
    if (locateHome && home === null) refreshHomeCache()
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
  function scanTunnelLog() {
    if (!watchingTunnelLog) return
    if (tunnelLogTail.running) { tunnelLogTail.again = true; return }
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
    scheduleLogScan()
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
      enqueue(["home", "forget"], "home", false, true)
    }
  }

  function refreshProcs() { enqueue(["procs"], "procs", true) }

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
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "adguardvpn-cli update"])
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
  function connectTo(cliName, city) {
    var target = String(cliName || "")
    if (target === "" || !installed) return
    _desired = 1
    pendingLocation = String(city || target)
    clearError()
    // The user (or startup auto-connect) is acting on the tunnel again — a
    // home lookup held since an earlier unexpected drop no longer needs to
    // wait; see dropHold / Model.mayLocateHome.
    dropHold = false
    enqueue(["connect", target], "connect")
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
      installed: installed, loggedIn: accountLoaded ? account.loggedIn : true, attempted: autoConnectAttempted })
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
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "adguardvpn-cli login"])
    actionStatus = "Log in from the terminal"
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
    var q = _queue.slice()
    q.push({ args: args, verb: verb, mutate: mutate === true, stdin: typeof stdin === "string" ? stdin : null })
    _queue = q
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
    else if (verb === "connect" || verb === "disconnect") applySnapshot(obj, verb === "disconnect")
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
    if (errorCode === "sudo_password") lastError = "sudo needs a password · see README"
  }

  // `requested`: the status came back from a disconnect the user asked for.
  function applySnapshot(obj, requested) {
    if (obj.ok === false) { noteError(obj); return }
    installed = true
    var snap = Model.normalizeSnapshot(obj)
    // Status the helper could not parse proves nothing about the tunnel: keep
    // the last known state instead of running the drop path, the kill switch
    // or startup auto-connect on it. A standing action/sudo error is not
    // papered over by this generic message either (Model.errorProtected).
    if (snap.state === "unknown") {
      if (!Model.errorProtected(errorSource)) { lastError = "Unrecognised adguardvpn-cli status output"; errorCode = "parse"; errorSource = ""; errorIntent = null }
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
    if (snap.state !== "connected") rates = { down: 0, up: 0 }
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
    procs = Model.toList(obj.procs)
  }

  function applyConfig(obj) {
    if (obj.ok === false) { noteError(obj); return }
    config = Model.normalizeConfig(obj)
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
    update = info
    root._updateRetryAt = 0
    persist({ lastUpdateCheck: Math.floor(Date.now() / 1000) })
    if (notifyIfAvailable && !info.upToDate && info.latest)
      notify("AdGuard VPN update", info.latest + " is available")
  }

  function applyLocations(obj) {
    if (obj.ok === false) { noteError(obj); return }
    locations = Model.normalizeLocations(obj)
  }

  function applyAccount(obj) {
    if (obj.ok === false) { noteError(obj); return }
    account = Model.normalizeAccount(obj)
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
    if (_prev) rates = Model.rateFrom(_prev, next, next.at - _prev.at)
    _prev = next
    rx = next.rx
    tx = next.tx
  }

  // --- timers -------------------------------------------------------------------
  Timer {
    id: refreshTimer
    interval: (root.panelOpen ? root.refreshIntervalSec : root.refreshIntervalSec * 2) * 1000
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
    running: true
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
    interval: 2000
    repeat: true
    running: root.connected && root.iface !== "" && (root.panelOpen || root.barMode === "rate")
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
    interval: 3000
    repeat: true
    onTriggered: {
      ticks += 1
      root.refreshAccount()
      if (root.account.loggedIn || ticks >= 100) { loginPoll.stop(); root.refresh() }
    }
  }

  onPanelOpenChanged: if (panelOpen) refreshAll()
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
      var ok = obj.ok !== false && exitCode === 0
      var isAction = root._refreshVerbs.indexOf(verb) === -1
      // Whatever connect job this was (auto-connect's own or a manual one
      // queued behind it — the queue never runs two at once), it has now
      // finished or failed either way: a home lookup held for
      // autoConnectPending is free to run again on the next snapshot.
      if (verb === "connect") root.autoConnectPending = false
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
        delayedRefresh.restart()
      }
      root.pump()
    }
  }
}
