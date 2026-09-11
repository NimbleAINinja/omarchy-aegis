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
  property string view: "list"            // list | exclusions | account
  property string focusSection: "header"  // header | list | footer
  property int cursorIndex: 0
  property int footerIndex: 0
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
  readonly property string statusLine: vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError
  readonly property color heroIconColor: vpn.vpnState === "logged_out" || !vpn.installed ? urgent : (vpn.active ? glow : dim)
  readonly property string barGlyph: "󰒘"
  readonly property string barText: verticalBar ? "" : Model.barLabel(barMode, snapForMeta, vpn.rates)
  readonly property string barTooltip: vpn.connected ? (vpn.location + (vpn.iso ? " · " + vpn.iso : "")) : heroMeta

  function countryFor(iso) {
    var list = vpn.locations
    for (var i = 0; i < list.length; i++) if (list[i].iso === iso) return list[i].country
    return ""
  }

  function switchView(next) {
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
  readonly property int listCount: viewLoader.item ? viewLoader.item.count : 0

  function ensureCursor() {
    if (focusSection === "list" && listCount === 0) focusSection = "header"
    if (cursorIndex >= listCount) cursorIndex = Math.max(0, listCount - 1)
    if (cursorIndex < 0) cursorIndex = 0
    if (footerIndex < 0) footerIndex = 0
    if (footerIndex > 5) footerIndex = 5
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
      if (focusSection === "footer") footerIndex = Math.max(0, Math.min(5, footerIndex + dx))
      else if (viewLoader.item && typeof viewLoader.item.moveHorizontal === "function") viewLoader.item.moveHorizontal(dx)
    }
    ensureCursor()
    if (focusSection === "list" && viewLoader.item && typeof viewLoader.item.ensureVisible === "function")
      viewLoader.item.ensureVisible(cursorIndex)
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") vpn.toggleVpn()
    else if (focusSection === "list" && viewLoader.item) viewLoader.item.activate(cursorIndex)
    else if (focusSection === "footer") footerAction(footerIndex)
  }

  function footerAction(index) {
    if (index === 0) switchView("exclusions")
    else if (index === 1) switchView("account")
    else if (index === 2) switchView("settings")
    else if (index === 3) switchView("killswitch")
    else if (index === 4) cycleBarMode()
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
    var k = t.toLowerCase()
    if (k === "t") { vpn.toggleVpn(); return }
    if (k === "d") { if (vpn.active) vpn.down(); return }
    if (k === "r") { vpn.refreshAll(true); return }
    if (k === "e") { switchView("exclusions"); return }
    if (k === "a") { switchView("account"); return }
    if (k === "s") { switchView("settings"); return }
    if (t === "K") { switchView("killswitch"); return }  // plain k is cursor-up in the key catcher
    if (k === "p" && view === "exclusions" && focusSection === "list") {
      if (viewLoader.item && typeof viewLoader.item.pauseAt === "function") viewLoader.item.pauseAt(cursorIndex)
      return
    }
    if (k === "f" && view === "list" && focusSection === "list") {
      if (viewLoader.item && typeof viewLoader.item.favoriteAt === "function") viewLoader.item.favoriteAt(cursorIndex)
      return
    }
    if (view === "list" && viewLoader.item && typeof viewLoader.item.focusSearch === "function") {
      viewLoader.item.focusSearch(k === "/" ? "" : t)
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
      if (vpn.vpnState === "logged_out") view = "account"
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onListCountChanged: ensureCursor()

  Connections {
    target: vpn
    function onPersist(values) { root.persistSettings(values) }
    function onVpnStateChanged() { if (vpn.vpnState === "logged_out") root.view = "account" }
    function onActionFinished(verb, ok) { if (ok && verb === "connect") root.view = "list" }
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
        editing: viewLoader.item ? viewLoader.item.editing : null })
    }
    function view(name: string): string {
      var v = String(name)
      if (["list", "exclusions", "account", "settings", "killswitch"].indexOf(v) === -1) return "unknown view"
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: viewLoader.item ? viewLoader.item.editing === true : false
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: { if (root.view !== "list") root.switchView("list"); else root.close() }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.focusSection === "list" && viewLoader.item && typeof viewLoader.item.removeAt === "function") viewLoader.item.removeAt(root.cursorIndex)
      onTextKey: function(t) { root.handleTextKey(t) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
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
            textColor: root.foreground
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
            visible: root.statusLine !== ""
            width: parent.width
            text: root.statusLine
            color: vpn.lastError !== "" && vpn.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Loader {
            id: viewLoader
            width: parent.width
            sourceComponent: root.view === "exclusions" ? exclusionsView
              : (root.view === "account" ? accountView
              : (root.view === "settings" ? settingsView
              : (root.view === "killswitch" ? killSwitchView : locationView)))
          }

          PanelSeparator { foreground: root.foreground }

          Row {
            id: footer
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: [
                { icon: "󰈲", tip: "Exclusions (e)" },
                { icon: "󰀄", tip: "Account (a)" },
                { icon: "󰒓", tip: "Settings (s)" },
                { icon: vpn.killSwitch ? "󰯆" : "󰯇", tip: vpn.killSwitch ? "Kill switch armed (K)" : "Kill switch (K)" },
                { icon: root.barMode === "iso" ? "󰬴" : (root.barMode === "rate" ? "󰓅" : "󰒘"), tip: "Bar shows " + root.barMode },
                { icon: "󰑐", tip: "Refresh (r)" }
              ]
              PanelActionButton {
                required property var modelData
                required property int index
                iconText: modelData.icon
                tooltipText: modelData.tip
                foreground: (index === 0 && root.view === "exclusions") || (index === 1 && root.view === "account")
                  || (index === 2 && root.view === "settings") || (index === 3 && (root.view === "killswitch" || vpn.killSwitch)) ? root.glow : root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "footer" && root.footerIndex === index
                onHovered: function(on) { if (on) root.setFooterCursor(index) }
                onClicked: root.footerAction(index)
                NumberAnimation on rotation {
                  running: index === 5 && vpn.refreshing
                  from: 0; to: 360; duration: 900; loops: Animation.Infinite
                  onRunningChanged: if (!running) parent.rotation = 0
                }
              }
            }

            Item { width: 1; height: 1 }
          }
        }
      }
    }
  }

  Component { id: locationView; LocationList { panel: root; vpn: root.service } }
  Component { id: exclusionsView; ExclusionsView { panel: root; vpn: root.service } }
  Component { id: accountView; AccountView { panel: root; vpn: root.service } }
  Component { id: settingsView; SettingsView { panel: root; vpn: root.service } }
  Component { id: killSwitchView; KillSwitchView { panel: root; vpn: root.service } }

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
