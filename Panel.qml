import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Grid.js" as Grid

// Aegis: AdGuard VPN bar widget + popup. UI only — all state and processes
// live in Service.qml, all pure logic in Model.js.
Panel {
  id: root
  moduleName: "io.github.nimbleaininja.aegis"
  ipcTarget: "io.github.nimbleaininja.aegis"
  manageIpc: false

  // --- theme ------------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  // The shell's "selected" state colour — what the toggle switch, selected rows
  // and the bar's active icons light up with. Using it for the live link keeps
  // Aegis consistent with the rest of the panel chrome in every theme.
  readonly property color glow: Style.selectedStateColor(foreground, accent)
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent)
  readonly property bool verticalBar: bar ? bar.vertical === true : false

  // --- persisted settings (inline on this widget's shell.json entry) ---------
  readonly property var favorites: Model.toList(setting("favorites", []))
  readonly property string lastLocation: String(setting("lastLocation", ""))
  readonly property string barMode: String(setting("barMode", "icon"))

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    for (var name in values) entry[name] = values[name]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleFavorite(loc) {
    if (!loc) return
    persistSettings({ favorites: Model.toggleFavorite(favorites, Model.locationKey(loc)) })
  }

  function cycleBarMode() { setBarMode(Model.nextBarMode(barMode)) }
  function setBarMode(mode) {
    var m = String(mode)
    if (["icon", "iso", "rate"].indexOf(m) === -1) m = "icon"
    persistSettings({ barMode: m })
  }

  // --- ui state --------------------------------------------------------------------
  // list | exclusions | account | settings | killswitch | traffic. Remembered
  // for as long as the shell runs, so closing the panel on the settings tab and
  // reopening it lands back on the settings tab; never persisted, so every
  // shell start opens on the list.
  property string view: "list"
  property string focusSection: "header"  // header | list | footer
  property int cursorIndex: 0
  property int footerIndex: 0
  // Last index of the footer Repeater's model below — the cursor clamp. The
  // model is a literal there (a Repeater given a new model rebuilds every
  // button, so it must not be an expression); tests/model.test.js reads the
  // literal and checks this number against its length.
  readonly property int footerLastIndex: 7
  property bool cursorActive: false
  property string query: ""
  property double nowMs: Date.now()

  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  // Favorites used for ORDERING are frozen while the panel is open, so starring
  // a row never yanks it out from under the pointer; the live `favorites` still
  // drives the star itself. Re-snapshotted on open.
  property var orderFavorites: []
  // The last-connected city is frozen the same way and for the same reason.
  // connectTo() persists it before the connect even starts, so with the live
  // value here every click on a row re-ran orderLocations, handed the ListView
  // a brand-new array and rebuilt every delegate under the user's cursor —
  // while the row they just clicked was busy turning into the pending one.
  // Only the per-row `last` flag depends on it (never the order), so a value
  // one open old shows exactly the same list in exactly the same indexes.
  property string orderLast: ""
  readonly property var orderedLocations: Model.orderLocations(vpn.locations, orderFavorites, orderLast)
  readonly property var visibleLocations: Model.filterLocations(orderedLocations, query)
  readonly property var exitLocation: Model.findLocation(vpn.locations, vpn.pendingLocation !== "" ? vpn.pendingLocation : vpn.location)
  readonly property var exitPoint: exitLocation && exitLocation.lat !== null && exitLocation.lon !== null
    ? { lat: exitLocation.lat, lon: exitLocation.lon, label: exitLocation.city } : null
  // The row under the cursor (mouse or keyboard) rings its city on the map.
  readonly property var hoverLocation: view === "list" && cursorActive && focusSection === "list"
    && cursorIndex >= 0 && cursorIndex < visibleLocations.length ? visibleLocations[cursorIndex] : null
  readonly property var hoverPoint: hoverLocation && hoverLocation.lat !== null && hoverLocation.lon !== null
    ? { lat: hoverLocation.lat, lon: hoverLocation.lon } : null
  readonly property var homePoint: vpn.homePoint
    ? { lat: vpn.homePoint.lat, lon: vpn.homePoint.lon, label: vpn.home ? String(vpn.home.city || "") : "" } : null
  readonly property var snapForMeta: ({ state: vpn.vpnState, iso: vpn.iso, endpoint: vpn.endpoint, sinceEpoch: vpn.sinceEpoch,
    mode: vpn.mode, listen: vpn.listen })
  readonly property string rateText: vpn.connected && (vpn.rates.down > 0 || vpn.rates.up > 0)
    ? "↓" + Model.formatRate(vpn.rates.down) + " ↑" + Model.formatRate(vpn.rates.up) : ""
  readonly property string heroTitle: {
    if (!vpn.installed) return "Aegis"
    if (vpn.pendingLocation !== "") return vpn.pendingLocation
    if (vpn.connected && vpn.location !== "") return vpn.location
    return "Aegis"
  }
  readonly property string heroMeta: {
    if (!vpn.installed) return "adguardvpn-cli not found"
    if (vpn.vpnState === "logged_out") return "Signed out"
    if (vpn.pendingLocation !== "" || vpn.vpnState === "connecting") return "Connecting"
    if (vpn.connected) {
      var meta = Model.heroMeta(snapForMeta, nowMs, countryFor)
      return rateText !== "" ? meta + "  " + rateText : meta
    }
    return "Off"
  }
  // The first prerequisite still missing (Model.setupStep) and the one-line
  // way to fix it, shown under the status line until nothing is in the way.
  readonly property string setupStep: Model.setupStep(vpn.installed, vpn.vpnState, vpn.sudoRule, vpn.nextMode)
  readonly property var setupPrompt: Model.setupPrompt(setupStep)
  // The three steps and where the user is in them, for the banner over the
  // map. Empty once nothing is in the way, which takes the banner away.
  readonly property var setupPlan: Model.setupPlan(setupStep)
  // No CLI or no login: the card is the hero and its one button. Every tab
  // below it is a question only the CLI can answer, and the icon bar only
  // leads between them — so both stand down rather than offering a dead
  // search field over an empty list and six tabs that say the same thing.
  readonly property bool setupOnly: Model.setupBlocks(setupStep)
  function runSetup() {
    if (setupStep === "install") vpn.openInstallGuide()
    else if (setupStep === "login") vpn.login()
    else if (setupStep === "sudo") vpn.openSudoHelp()
  }
  readonly property string statusLine: vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError
  readonly property color statusColor: vpn.lastError !== "" && vpn.actionStatus === "" ? urgent : dim
  readonly property color heroIconColor: vpn.vpnState === "logged_out" || !vpn.installed ? urgent : (vpn.active ? glow : dim)
  readonly property string barGlyph: "󰒘"
  readonly property string barText: verticalBar ? "" : Model.barLabel(barMode, snapForMeta, vpn.rates)
  readonly property string barTooltip: vpn.connected ? (vpn.location + (vpn.iso ? " · " + vpn.iso : "")) : heroMeta

  // heroMeta calls countryFor from a binding that re-runs on every rate tick
  // (two seconds, while connected with the panel open) and on every uptime
  // tick; it used to walk all ~90 locations each time for one ISO code. The
  // map is rebuilt only when the location list itself changes.
  readonly property var countryByIso: Model.countryIndex(vpn.locations)
  // The map's ping tints, built once per locations change: WorldMap paints the
  // land dot nearest each city in its ping tier's colour, and it cannot call
  // Model.pingTier itself (it imports only QtQuick, Grid.js and Link.js, so
  // that it can be rendered headlessly).
  readonly property var dotTints: Model.dotTints(vpn.locations)
  function countryFor(iso) { return Model.countryFrom(countryByIso, iso) }

  function switchView(next) {
    // Asking for the view you are already in returns to the list, so every
    // footer button is a toggle. "list" is its own fallback, so the footer's
    // map pin pressed on the list simply leaves you there.
    view = view === next ? "list" : next
    // A new view starts with the keyboard cursor parked on the header, so the
    // first Down always lands on the view's first row.
    cursorActive = false
    focusSection = "header"
    cursorIndex = 0
    if (view === "exclusions") vpn.refreshExclusions()
    if (view === "account") vpn.refreshAccount()
    if (view === "settings") vpn.refreshConfig()
    if (view === "killswitch") vpn.refreshProcs()
  }

  // --- cursor ----------------------------------------------------------------------
  readonly property int listCount: root.viewItem ? root.viewItem.count : 0

  function ensureCursor() {
    // Setup-only: the hero's button is the only control on the card, so the
    // cursor has nowhere else to go and j/k/arrows leave it there.
    if (setupOnly) { focusSection = "header"; cursorIndex = 0; footerIndex = 0; return }
    if (focusSection === "list" && listCount === 0) focusSection = "header"
    if (cursorIndex >= listCount) cursorIndex = Math.max(0, listCount - 1)
    if (cursorIndex < 0) cursorIndex = 0
    if (footerIndex < 0) footerIndex = 0
    if (footerIndex > footerLastIndex) footerIndex = footerLastIndex
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy !== 0) {
      if (focusSection === "header") {
        if (dy > 0) focusSection = listCount > 0 ? "list" : "footer"
      } else if (focusSection === "list") {
        if (dy < 0) { if (cursorIndex <= 0) focusSection = "header"; else cursorIndex-- }
        else { if (cursorIndex < listCount - 1) cursorIndex++; else focusSection = "footer" }
      } else if (focusSection === "footer") {
        if (dy < 0) focusSection = listCount > 0 ? "list" : "header"
      }
    } else if (dx !== 0) {
      if (focusSection === "footer") footerIndex = Math.max(0, Math.min(footerLastIndex, footerIndex + dx))
      else if (root.viewItem && typeof root.viewItem.moveHorizontal === "function") root.viewItem.moveHorizontal(dx)
    }
    ensureCursor()
    if (focusSection === "list" && root.viewItem && typeof root.viewItem.ensureVisible === "function")
      root.viewItem.ensureVisible(cursorIndex)
  }

  function activateCursor() {
    ensureCursor()
    // The hero's switch is hidden until the prerequisites are met; while it
    // is, Enter on the header runs the step the prompt is offering.
    if (focusSection === "header") { if (setupOnly) runSetup(); else vpn.toggleVpn() }
    else if (focusSection === "list" && root.viewItem) root.viewItem.activate(cursorIndex)
    else if (focusSection === "footer") footerAction(footerIndex)
  }

  function footerAction(index) {
    if (index === 0) switchView("list")
    else if (index === 1) switchView("exclusions")
    else if (index === 2) switchView("account")
    else if (index === 3) switchView("settings")
    else if (index === 4) switchView("killswitch")
    else if (index === 5) switchView("traffic")
    else if (index === 6) cycleBarMode()
    // The footer's refresh button is an explicit ask: refetch the location
    // list even if the one on screen is still within its TTL.
    else vpn.refreshAll(true)
  }

  function setListCursor(index) { cursorActive = true; focusSection = "list"; cursorIndex = index }
  function setFooterCursor(index) { cursorActive = true; focusSection = "footer"; footerIndex = index }
  function setHeaderCursor() { cursorActive = true; focusSection = "header" }
  function keyCatcherFocus() { keyCatcher.forceActiveFocus() }

  function connectTo(loc) {
    if (!loc) return
    persistSettings({ lastLocation: loc.city })
    vpn.connectTo(loc.cliName, loc.city)
  }

  function handleTextKey(t) {
    // Before the lowercasing below, where plain t is the VPN toggle.
    if (t === "T") { switchView("traffic"); return }
    var k = t.toLowerCase()
    if (k === "t") { vpn.toggleVpn(); return }
    if (k === "d") { if (vpn.active) vpn.down(); return }
    if (k === "r") { vpn.refreshAll(true); return }
    if (k === "e") { switchView("exclusions"); return }
    if (k === "a") { switchView("account"); return }
    if (k === "s") { switchView("settings"); return }
    if (t === "K") { switchView("killswitch"); return }  // plain k is cursor-up in the key catcher
    if (t === "L") { switchView("list"); return }        // plain l is cursor-right
    if (k === "p" && view === "exclusions" && focusSection === "list") {
      if (root.viewItem && typeof root.viewItem.pauseAt === "function") root.viewItem.pauseAt(cursorIndex)
      return
    }
    if (k === "f" && view === "list" && focusSection === "list") {
      if (root.viewItem && typeof root.viewItem.favoriteAt === "function") root.viewItem.favoriteAt(cursorIndex)
      return
    }
    if (view === "list" && root.viewItem && typeof root.viewItem.focusSearch === "function") {
      root.viewItem.focusSearch(k === "/" ? "" : t)
    }
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      focusSection = "header"
      query = ""
      orderFavorites = favorites
      orderLast = lastLocation
      nowMs = Date.now()
      if (panelFlick) panelFlick.contentY = 0
      // `view` is deliberately not reset: the panel reopens on the tab it was
      // closed on. Being signed out is the exception — the account tab is the
      // only one worth anything then.
      if (vpn.vpnState === "logged_out") view = "account"
      // Build the popup content, if this is the first open — after the resets
      // above, so the rows and the view Loader are built once, already showing
      // what this open should show. Loaders are synchronous, so the column
      // exists by the time the card is measured on this same change and there
      // is no first-open size pop.
      popupReady = true
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onListCountChanged: ensureCursor()

  // A connect is not a reason to move the user somewhere else: clicking a city
  // on the map, or connecting from the settings tab, used to yank the panel
  // back to the location list the moment the tunnel came up, hiding the very
  // view the click came from. The only state change that still forces a view is
  // being signed out, where nothing else is usable.
  Connections {
    target: vpn
    function onPersist(values) { root.persistSettings(values) }
    function onVpnStateChanged() { if (vpn.vpnState === "logged_out") root.view = "account" }
  }

  // Views take the service through a differently named alias: a `vpn: vpn`
  // binding would resolve to the view's own (null) property, not this id.
  readonly property var service: vpn

  Service {
    id: vpn
    settings: root.settings
    panelOpen: root.opened
  }

  Timer {
    interval: 30000
    running: root.opened && vpn.connected
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function isOpen(): string { return root.opened ? "true" : "false" }
    function refresh(): string { vpn.refreshAll(true); return "ok" }
    function up(): string { if (!vpn.active) vpn.toggleVpn(); return "ok" }
    function down(): string { vpn.down(); return "ok" }
    function toggleVpn(): string { vpn.toggleVpn(); return "ok" }
    function connect(city: string): string {
      var loc = Model.findLocation(vpn.locations, city)
      if (loc) { root.connectTo(loc); return "ok" }
      // Locations may not be loaded yet; the CLI resolves city names itself.
      var name = String(city).trim()
      if (name === "") return "no location"
      root.persistSettings({ lastLocation: name })
      vpn.connectTo(name, name)
      return "ok"
    }
    function barMode(mode: string): string { root.setBarMode(mode); return root.barMode }
    function debug(): string {
      return JSON.stringify({ view: root.view, focusSection: root.focusSection, cursorIndex: root.cursorIndex,
        cursorActive: root.cursorActive, listCount: root.listCount, footerIndex: root.footerIndex,
        editing: root.viewItem ? root.viewItem.editing : null })
    }
    function view(name: string): string {
      var v = String(name)
      if (["list", "exclusions", "account", "settings", "killswitch", "traffic"].indexOf(v) === -1) return "unknown view"
      root.switchView(v)
      if (root.view !== v) root.switchView(v)
      return root.view
    }
    function status(): string {
      return JSON.stringify({ state: vpn.vpnState, location: vpn.location, iso: vpn.iso,
        endpoint: vpn.endpoint, sinceEpoch: vpn.sinceEpoch, rates: vpn.rates, home: vpn.home })
    }
  }

  // --- bar widget --------------------------------------------------------------------
  implicitWidth: barLoader.item ? barLoader.item.implicitWidth : 0
  implicitHeight: barLoader.item ? barLoader.item.implicitHeight : 0

  Loader {
    id: barLoader
    anchors.fill: parent
    sourceComponent: root.barText === "" ? iconButton : textButton
  }

  Component {
    id: iconButton
    BarIconButton {
      bar: root.bar
      text: root.barGlyph
      active: vpn.connected || vpn.vpnState === "logged_out" || !vpn.installed
      activeColor: vpn.vpnState === "logged_out" || !vpn.installed ? root.urgent : root.glow
      dimmed: !vpn.active && vpn.vpnState !== "logged_out" && vpn.installed
      tooltipText: root.barTooltip
      onPressed: function(buttonCode) { root.barPressed(buttonCode) }
      SequentialAnimation on opacity {
        running: vpn.linkState === "connecting"
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 500; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
        onRunningChanged: if (!running) parent.opacity = 1
      }
    }
  }

  Component {
    id: textButton
    WidgetButton {
      bar: root.bar
      text: root.barGlyph + " " + root.barText
      active: true
      activeColor: root.glow
      tooltipText: root.barTooltip
      onPressed: function(buttonCode) { root.barPressed(buttonCode) }
    }
  }

  function barPressed(buttonCode) {
    if (buttonCode === Qt.RightButton) vpn.toggleVpn()
    else if (buttonCode === Qt.MiddleButton) vpn.refreshAll(true)
    else root.toggle()
  }

  // --- popup -------------------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: barLoader
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(root.popupContentHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.viewItem ? root.viewItem.editing === true : false
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      // Esc closes from every view. It used to walk back to the list first,
      // which cost a keypress to leave a tab and threw away the view the next
      // open should have come back to. A focused search field still gets Esc
      // to itself (it clears the text): `blocked` is true while it is editing.
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.focusSection === "list" && root.viewItem && typeof root.viewItem.removeAt === "function") root.viewItem.removeAt(root.cursorIndex)
      onTextKey: function(t) { root.handleTextKey(t) }

      // The map, the hero and the status line, pinned to the top of the card:
      // they are what the panel IS — where the tunnel comes out, whether it is
      // up, what just went wrong — and they used to be the first thing scrolled
      // away by a long location list, leaving the user reading rows with no
      // idea what they were connected to. Everything heavy is behind this
      // Loader: two Canvas image buffers (~378 KB each) that would otherwise be
      // built per screen at shell start-up for a popup the user may never open.
      Loader {
        id: headerLoader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        active: root.popupReady
        sourceComponent: popupHeader
      }

      // The scrolling middle: the current tab, and nothing else. It starts one
      // gap below the header's rule and ends where the footer begins, so a view
      // taller than the card scrolls between two things that stay put. Before
      // the first open both Loaders are inactive and zero-high, and this fills
      // the card — with nothing in it.
      Flickable {
        id: panelFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: headerLoader.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: footerLoader.top
        contentWidth: width
        contentHeight: root.popupColumnHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // The view's own rows — the whole location list, the settings tab —
        // deferred on the same latch as the header above and the footer below.
        // All three activate the moment `opened` flips, which is when
        // KeyboardPanel starts its 140 ms fade-in and not when the fade
        // finishes, so the card is measured with everything already there and
        // never pops. None of them deactivate: a panel opened once is one the
        // user opens again.
        Loader {
          id: contentLoader
          width: panelFlick.width
          active: root.popupReady && !root.setupOnly
          sourceComponent: popupContent
        }
      }

      // The icon bar sits outside the Flickable, pinned to the bottom of the
      // card: it used to be the last row of the scrolling column, so on a long
      // location list or the settings tab it scrolled out of reach and the way
      // to another tab was to scroll back down. Lazy on the same latch as the
      // header and the view, so the first open builds all three at once and the
      // card measures them together.
      Loader {
        id: footerLoader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        active: root.popupReady && !root.setupOnly
        sourceComponent: popupFooter
      }
    }
  }

  // How tall the scrolling column wants to be: what the Flickable scrolls
  // through, which is now the current view alone. 0 before the first open.
  readonly property real popupColumnHeight: contentLoader.item ? contentLoader.item.implicitHeight : 0
  readonly property real popupHeaderHeight: headerLoader.item ? headerLoader.item.implicitHeight : 0
  readonly property real popupFooterHeight: footerLoader.item ? footerLoader.item.implicitHeight : 0
  // What the card sizes itself to: the pinned header, the view, the pinned
  // footer, and a column gap on either side of the view. Still content-sized
  // up to the cap, so a short tab is still a short card. 0 before the first
  // open, when fittedContentHeight falls back to the card's own insets and
  // nothing is drawn anyway.
  // Setup-only, the view and the footer are both inactive and zero-high, so
  // the card is the header plus the gap under it — not the 0 that means
  // "never opened" and draws nothing at all.
  readonly property real popupContentHeight: root.setupOnly
    ? (popupHeaderHeight > 0 ? popupHeaderHeight + Style.space(10) : 0)
    : (popupColumnHeight > 0
      ? popupHeaderHeight + Style.space(10) + popupColumnHeight + Style.space(10) + popupFooterHeight : 0)
  // The current view's item, or null before the popup has ever been built.
  // This is the only way into the deferred content — the view Loader's id
  // lives inside the Component — and every use of it above checks for null
  // first: the bar icon and the IPC verbs (connect/down/toggleVpn/status/
  // barMode/view) must work with the popup never opened, and `view <name>`
  // only sets root.view, which the view Loader picks up whenever it is built.
  readonly property var viewItem: contentLoader.item ? contentLoader.item.viewItem : null
  // Latched on the first open and never cleared.
  property bool popupReady: false

  Component {
    id: popupHeader

    // Map, hero, status line and the rule under them, as one block the card
    // can measure and the Flickable can start below.
    Column {
      id: headerBlock
      spacing: Style.space(10)

      WorldMap {
        id: map
        width: parent.width
        grid: root.landGrid
        dotPitch: Style.space(4)
        dotColor: Util.alpha(root.foreground, 0.22)
        gridColor: Util.alpha(root.foreground, 0.06)
        markerColor: root.glow
        accent: root.glow
        // The same three colours the list's ping dots use (LocationList's
        // tierColor), so one reading works across both.
        dotTints: root.dotTints
        tintDots: vpn.pingDots
        goodColor: root.glow
        okColor: Util.alpha(root.foreground, 0.6)
        poorColor: root.urgent
        textColor: root.foreground
        dimTextColor: root.dim
        haloColor: Util.alpha(Color.popups.background, 0.92)
        fontFamily: root.fontFamily
        labelPixelSize: Style.font.caption
        home: root.homePoint
        exit: root.exitPoint
        hover: root.hoverPoint
        candidates: vpn.locations
        onCandidateClicked: function(location) { root.connectTo(location) }
        linkState: vpn.linkState
        animate: root.opened

        // First run, over the map it has nothing to show on yet: what the
        // three steps are, which one is live, and that each one hands the
        // panel back. No MouseArea, so a map with cities on it (the sudo
        // step, where the list is already loaded) stays clickable around it.
        Rectangle {
          id: setupBanner
          visible: root.setupPlan.length > 0
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(48), Style.space(320))
          height: planColumn.implicitHeight + Style.space(28)
          radius: Style.cornerRadius
          // The halo the map already puts behind its own city labels, so the
          // banner reads as part of the map rather than a card dropped on it.
          color: Util.alpha(Color.popups.background, 0.92)
          border.width: 1
          border.color: Util.alpha(root.foreground, 0.14)

          Column {
            id: planColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(28)
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.SETUP_INTRO
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.setupPlan

                Row {
                  required property var modelData
                  spacing: Style.space(8)
                  // The step the user is on is the only bright line; a step
                  // already behind them trades its number for a tick.
                  readonly property bool live: modelData.state === "current"
                  readonly property color tone: live ? root.foreground : root.dim

                  Text {
                    textFormat: Text.PlainText
                    width: Style.space(10)
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData.state === "done" ? "\u{F012C}" : modelData.n
                    color: parent.tone
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: parent.tone
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }
        }
      }

      Item {
        id: header
        width: parent.width
        implicitHeight: hero.implicitHeight
        readonly property bool ringVisible: root.headerHasCursor
        readonly property color iconColor: root.heroIconColor
        readonly property string switchTip: vpn.active ? "Disconnect (t)" : (root.lastLocation !== "" ? "Connect to " + root.lastLocation + " (t)" : "Connect to fastest (t)")
        function focusHero() { root.setHeaderCursor() }

        PanelHero {
          id: hero
          width: parent.width
          title: root.heroTitle
          meta: root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "󰒘"
              color: header.iconColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              Behavior on color { ColorAnimation { duration: 160 } }
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: powerSwitch
              visible: vpn.installed && vpn.vpnState !== "logged_out"
              checked: vpn.active
              busy: vpn.busy
              hasCursor: header.ringVisible
              foreground: hero.foreground
              onHovered: function(on) { if (on) header.focusHero() }
              onToggled: vpn.toggleVpn()
              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: header.switchTip
                fontFamily: hero.fontFamily
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.statusLine !== "" && Model.showsStatus(vpn.actionStatus, vpn.errorCode, root.setupStep)
        width: parent.width
        text: root.statusLine
        color: root.statusColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Row {
        id: setupRow
        visible: root.setupStep !== ""
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          width: setupRow.width - setupButton.width - setupRow.spacing
          anchors.verticalCenter: parent.verticalCenter
          text: root.setupPrompt.text
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Button {
          id: setupButton
          anchors.verticalCenter: parent.verticalCenter
          // The only control on a setup-only card, so it wears the cursor.
          hasCursor: root.setupOnly && root.headerHasCursor
          text: root.setupPrompt.button
          iconText: root.setupPrompt.icon
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.runSetup()
        }
      }

      // The rule that divides the hero from the tab below it. Setup-only
      // there is no tab, so it would hang under the prompt dividing nothing.
      PanelSeparator { foreground: root.foreground; visible: !root.setupOnly }
    }
  }

  Component {
    id: popupContent

    // The scrolling part of the card: the current tab and nothing else.
    Column {
      id: column
      spacing: Style.space(10)
      // How Panel.qml's own functions reach into the loaded content.
      readonly property var viewItem: viewLoader.item

      Loader {
        id: viewLoader
        width: parent.width
        sourceComponent: root.view === "exclusions" ? exclusionsView
          : (root.view === "account" ? accountView
          : (root.view === "settings" ? settingsView
          : (root.view === "killswitch" ? killSwitchView
          : (root.view === "traffic" ? trafficView : locationView))))
      }
    }
  }

  Component {
    id: popupFooter

    // Separator and icon bar in one block so the card can measure them as one
    // and the Flickable above can end at the separator.
    Column {
      id: footerBlock
      spacing: Style.space(10)

      PanelSeparator { foreground: root.foreground }

      Row {
        id: footer
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          // A constant list of ids, in footerAction's index order, with
          // root.footerLastIndex clamping the cursor to the last of them. The
          // model used to be an inline array literal whose entries read
          // vpn.killSwitch and root.barMode, so arming the kill switch or
          // cycling the bar mode rebuilt the array, and a Repeater given a
          // new model destroys and recreates every delegate: all of the
          // buttons, to change one glyph on one of them. The per-button
          // expressions now live in the delegate, where they change a
          // property on a button that stays put.
          model: ["list", "exclusions", "account", "settings", "killswitch", "traffic", "barmode", "refresh"]
          PanelActionButton {
            required property string modelData
            required property int index
            // Every id but "barmode" and "refresh" is also a view name, and
            // neither of those two can ever equal root.view.
            readonly property bool lit: modelData === "killswitch"
              ? (root.view === "killswitch" || vpn.killSwitch)
              : root.view === modelData
            iconText: {
              if (modelData === "list") return "󰍎"
              if (modelData === "exclusions") return "󰈲"
              if (modelData === "account") return "󰀄"
              if (modelData === "settings") return "󰒓"
              if (modelData === "killswitch") return vpn.killSwitch ? "󰯆" : "󰯇"
              if (modelData === "traffic") return "󰄨"
              if (modelData === "barmode") return root.barMode === "iso" ? "󰬴" : (root.barMode === "rate" ? "󰓅" : "󰒘")
              return "󰑐"
            }
            tooltipText: {
              if (modelData === "list") return "Locations (L)"
              if (modelData === "exclusions") return "Exclusions (e)"
              if (modelData === "account") return "Account (a)"
              if (modelData === "settings") return "Settings (s)"
              if (modelData === "killswitch") return vpn.killSwitch ? "Kill switch armed (K)" : "Kill switch (K)"
              if (modelData === "traffic") return "Traffic (T)"
              if (modelData === "barmode") return "Bar shows " + root.barMode
              return "Refresh (r)"
            }
            foreground: lit ? root.glow : root.dim
            hoverColor: root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.cursorActive && root.focusSection === "footer" && root.footerIndex === index
            onHovered: function(on) { if (on) root.setFooterCursor(index) }
            onClicked: root.footerAction(index)
            NumberAnimation on rotation {
              running: modelData === "refresh" && vpn.refreshing
              from: 0; to: 360; duration: 900; loops: Animation.Infinite
              onRunningChanged: if (!running) parent.rotation = 0
            }
          }
        }

        Item { width: 1; height: 1 }
      }
    }
  }

  Component { id: locationView; LocationList { panel: root; vpn: root.service } }
  Component { id: exclusionsView; ExclusionsView { panel: root; vpn: root.service } }
  Component { id: accountView; AccountView { panel: root; vpn: root.service } }
  Component { id: settingsView; SettingsView { panel: root; vpn: root.service } }
  Component { id: killSwitchView; KillSwitchView { panel: root; vpn: root.service } }
  Component { id: trafficView; TrafficView { panel: root; vpn: root.service } }

  // --- assets -------------------------------------------------------------------------
  property var landGrid: null
  function pluginFile(name) { return decodeURIComponent(Qt.resolvedUrl(name).toString().replace(/^file:\/\//, "")) }

  FileView {
    id: gridFile
    path: root.pluginFile("assets/land-grid.json")
    watchChanges: false
    onLoaded: {
      try { root.landGrid = Grid.decodeRle(JSON.parse(text())) }
      catch (e) { console.warn("aegis: land grid failed to load: " + e) }
    }
  }
}
