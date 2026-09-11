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

  function refreshAll() {
    refresh()
    refreshLocations()
    if (!accountLoaded) refreshAccount()
    refreshHome()
  }

  function refreshProcs() { enqueue(["procs"], "procs", true) }

  // Pausing takes the domain out of the CLI list but keeps it in our own
  // paused list (per mode), so resume can put it back.
  function setExclusionPaused(domain, paused) {
    var d = String(domain || "").trim().toLowerCase()
    if (d === "") return
    clearError()
    persist({ pausedExclusions: Model.setPaused(pausedExclusions, exclusions.mode, d, paused) })
    if (paused) enqueue(["exclusions", "remove", d], "exclusions", false, true)
    else enqueue(["exclusions", "add", d], "exclusions", false, true)
  }

  function forgetExclusion(domain) {
    var d = String(domain || "").trim().toLowerCase()
    if (d === "") return
    clearError()
    if (Model.setPaused(pausedExclusions, exclusions.mode, d, false)[exclusions.mode].length !== (pausedExclusions[exclusions.mode] || []).length)
      persist({ pausedExclusions: Model.setPaused(pausedExclusions, exclusions.mode, d, false) })
    if (exclusions.domains.indexOf(d) !== -1) enqueue(["exclusions", "remove", d], "exclusions", false, true)
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
    enqueue(["config", "set", k, String(value)], "config", false, true)
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
    enqueue(["connect", target], "connect")
  }

  function down() {
    if (!installed) return
    _desired = 0
    pendingLocation = ""
    clearError()
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
    var d = String(domain || "").trim()
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
  readonly property var _refreshVerbs: ["snapshot", "locations", "account", "exclusions", "home", "config", "update", "procs"]
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
  // is a _refreshVerbs entry — see jobProcess.onExited.
  function enqueue(args, verb, dedupe, mutate) {
    if (dedupe && ((jobProcess.running && jobProcess.verb === verb) || queued(verb))) return
    var q = _queue.slice()
    q.push({ args: args, verb: verb, mutate: mutate === true })
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
    jobProcess.command = helper(next.args)
    jobProcess.running = true
    jobWatchdog.interval = next.verb === "connect" ? 75000 : 20000
    jobWatchdog.restart()
  }

  function applyJob(verb, obj, exitCode) {
    if (verb === "snapshot") applySnapshot(obj)
    else if (verb === "locations") applyLocations(obj)
    else if (verb === "account") applyAccount(obj)
    else if (verb === "exclusions") applyExclusions(obj)
    else if (verb === "home") applyHome(obj)
    else if (verb === "config") applyConfig(obj)
    else if (verb === "update") applyUpdate(obj, _notifyUpdate)
    else if (verb === "procs") applyProcs(obj)
    else if (verb === "connect" || verb === "disconnect") applySnapshot(obj, verb === "disconnect")
    else if (verb === "logout") {
      // Logging out takes the tunnel down on request: an intentional
      // disconnect (kill switch only with killOnDisconnect), never a drop.
      var loss = Model.tunnelLoss(vpnState, "logged_out", true)
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
    // Judged before the pending toggle settles; see Model.settleStatus.
    var step = Model.settleStatus({ prevState: vpnState, nextState: snap.state, desired: _desired,
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
    if (snap.state === "connected") pendingLocation = ""
    if (snap.state === "logged_out") {
      account = Model.loggedOutAccount()
      accountLoaded = true
    }
    if (snap.state !== "connected") rates = { down: 0, up: 0 }
    if (snap.state === "disconnected" && homeStale) refreshHome()
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

  function applyHome(obj) {
    if (obj.ok === false) return
    home = obj.home && typeof obj.home === "object" ? obj.home : null
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
    id: jobWatchdog
    interval: 20000
    onTriggered: {
      if (!jobProcess.running) return
      var verb = jobProcess.verb
      jobProcess.running = false
      if (verb === "connect" || verb === "disconnect") {
        // The CLI often finishes the job after the watchdog gives up on it;
        // record what was wanted so a later snapshot proving it happened
        // anyway (Model.errorResolved) clears this without a new action.
        var intent = verb === "connect" ? { verb: "connect", target: root.pendingLocation } : { verb: "disconnect" }
        root._desired = -1
        root.pendingLocation = ""
        root.lastError = "Timed out waiting for adguardvpn-cli"
        root.errorCode = "timeout"
        root.errorSource = "action"
        root.errorIntent = intent
      }
      root.pump()
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
  onActionStatusChanged: if (actionStatus !== "") actionStatusTimer.restart()
  Component.onCompleted: {
    tzProcess.running = true
    refreshHome()
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

  Process {
    id: countersProcess
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyCounters(text) }
  }

  Process {
    id: jobProcess
    property string verb: ""
    property bool mutate: false
    property string output: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: jobProcess.output = text }
    onExited: function(exitCode) {
      jobWatchdog.stop()
      var verb = jobProcess.verb
      var mutate = jobProcess.mutate === true
      var obj = root.parseJson(jobProcess.output)
      jobProcess.output = ""
      var ok = obj.ok !== false && exitCode === 0
      var isAction = root._refreshVerbs.indexOf(verb) === -1
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
