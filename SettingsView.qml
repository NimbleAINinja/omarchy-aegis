import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Settings: the three things a tunnel needs (the CLI, an account, the sudo
// rule) with a button for each that is missing, then connection mode and
// protocol, SOCKS, DNS, and Aegis's own switches. Toggles and chips apply
// immediately; text fields apply on Enter.
Column {
  id: root
  property var panel: null
  property var vpn: null

  readonly property var config: vpn ? vpn.config : Model.normalizeConfig(null)
  readonly property bool socks: config.mode === "socks"
  // Keyboard cursor targets, top to bottom. Text fields are reached by mouse
  // or Tab; the cursor walks the toggles and chip rows.
  readonly property var targets: ["cli", "account", "sudoRule", "mode", "protocol", "postQuantum", "changeSystemDns", "autoConnect", "locateHome", "pingDots"]
  readonly property int count: targets.length
  readonly property bool editing: dnsField.activeFocus || hostField.activeFocus || userField.activeFocus
    || passField.activeFocus || portField.activeFocus
  readonly property string updateText: !vpn ? "" : (vpn.updateChecking ? "Checking"
    : (vpn.update.checkedAt === 0 ? "" : (vpn.update.upToDate ? "Up to date" : vpn.update.latest + " available")))
  readonly property bool updateReady: vpn ? !vpn.update.upToDate && !!vpn.update.latest : false
  // "in" / "out" / "unknown" — not a bool, because with no CLI the account
  // call never lands and the placeholder would read as signed in.
  readonly property string accountState: Model.accountState(vpn ? vpn.account : null, vpn ? vpn.accountLoaded : false)
  // Missing is not a fault: connects still work, in a terminal that asks
  // for the password. The README says how to do without that.
  readonly property string sudoText: !vpn ? ""
    : (vpn.sudoRule === "ok" ? "Set up" : (vpn.sudoRule === "missing" ? "None, connects ask for a password" : "Not checked"))

  spacing: Style.space(8)

  function hasCursor(name) {
    return panel.cursorActive && panel.focusSection === "list" && targets[panel.cursorIndex] === name
  }

  function activate(index) {
    var name = targets[index]
    if (name === "mode") vpn.setConfig("mode", socks ? "tun" : "socks")
    else if (name === "protocol") cycleProtocol(1)
    else if (name === "postQuantum") vpn.setConfig("postQuantum", !config.postQuantum)
    else if (name === "changeSystemDns") vpn.setConfig("changeSystemDns", !config.changeSystemDns)
    else if (name === "autoConnect") panel.persistSettings({ autoConnect: !vpn.autoConnect })
    else if (name === "locateHome") vpn.setLocateHome(!vpn.locateHome)
    else if (name === "pingDots") panel.persistSettings({ pingDots: !vpn.pingDots })
    else if (name === "cli") { if (!vpn.installed) vpn.openInstallGuide(); else if (updateReady) vpn.runUpdate(); else vpn.checkUpdate(false) }
    else if (name === "account") { if (root.accountState === "out") vpn.login() }
    else if (name === "sudoRule") { if (vpn.sudoRule !== "ok") vpn.openSudoHelp() }
  }

  function moveHorizontal(dx) {
    var name = targets[panel.cursorIndex]
    if (name === "mode") vpn.setConfig("mode", socks ? "tun" : "socks")
    else if (name === "protocol") cycleProtocol(dx)
  }

  function cycleProtocol(dx) {
    var order = ["auto", "http2", "quic"]
    var i = order.indexOf(config.protocol)
    vpn.setConfig("protocol", order[(i + dx + order.length) % order.length])
  }

  function setCursor(name) {
    var i = targets.indexOf(name)
    if (i !== -1) panel.setListCursor(i)
  }

  PanelSectionHeader {
    text: "SETUP"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  SetupRow {
    name: "cli"
    label: "AdGuard VPN CLI" + (vpn && vpn.installed && vpn.update.current ? " " + vpn.update.current : "")
    status: vpn && !vpn.installed ? "Not installed" : root.updateText
    statusHot: vpn ? vpn.installed && root.updateReady && vpn.update.checkedAt !== 0 : false
    buttonText: vpn && !vpn.installed ? "Guide" : (root.updateReady ? "Update" : "Check")
    buttonIcon: vpn && !vpn.installed ? Model.setupPrompt("install").icon : (root.updateReady ? "󰚰" : "󰑐")
    spinning: vpn ? vpn.updateChecking : false
  }

  SetupRow {
    name: "account"
    label: "Account"
    status: root.accountState === "unknown" ? "Not checked"
      : (root.accountState === "out" ? "Signed out"
      : (vpn && vpn.account.email ? vpn.account.email : "Signed in"))
    buttonVisible: root.accountState === "out"
    buttonText: "Log in"
    buttonIcon: Model.setupPrompt("login").icon
  }

  SetupRow {
    name: "sudoRule"
    label: "Sudo rule"
    status: root.sudoText
    statusHot: vpn ? vpn.sudoRule === "missing" : false
    buttonText: "README"
    buttonIcon: Model.setupPrompt("sudo").icon
    buttonVisible: vpn ? vpn.sudoRule !== "ok" : true
  }

  PanelSectionHeader {
    text: "CONNECTION"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  ChipRow {
    label: "Mode"
    options: [{ value: "tun", label: "TUN", tooltip: "System-wide tunnel" }, { value: "socks", label: "SOCKS", tooltip: "Local proxy on the SOCKS port" }]
    value: root.config.mode
    cursorName: "mode"
    onPicked: function(v) { vpn.setConfig("mode", v) }
  }

  ChipRow {
    label: "Protocol"
    options: [{ value: "auto", label: "Auto" }, { value: "http2", label: "HTTP/2" }, { value: "quic", label: "QUIC" }]
    value: root.config.protocol
    cursorName: "protocol"
    onPicked: function(v) { vpn.setConfig("protocol", v) }
  }

  Toggle {
    width: parent.width
    label: "Post-quantum cryptography"
    checked: root.config.postQuantum
    hasCursor: root.hasCursor("postQuantum")
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    onHovered: function(on) { if (on) root.setCursor("postQuantum") }
    onClicked: vpn.setConfig("postQuantum", !root.config.postQuantum)
  }

  Column {
    visible: root.socks
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: "SOCKS"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      TextField {
        id: hostField
        Layout.fillWidth: true
        foreground: panel.foreground
        placeholderText: "Host  " + root.config.socksHost
        onAccepted: { if (text.trim() !== "") vpn.setConfig("socksHost", text.trim()); text = ""; panel.keyCatcherFocus() }
        Keys.onEscapePressed: { text = ""; panel.keyCatcherFocus() }
      }

      TextField {
        id: portField
        Layout.preferredWidth: Style.space(140)
        foreground: panel.foreground
        placeholderText: "Port  " + root.config.socksPort
        validator: IntValidator { bottom: 1; top: 65535 }
        onAccepted: { if (acceptableInput && text !== "") vpn.setConfig("socksPort", parseInt(text, 10)); text = ""; panel.keyCatcherFocus() }
        Keys.onEscapePressed: { text = ""; panel.keyCatcherFocus() }
      }
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      TextField {
        id: userField
        Layout.fillWidth: true
        foreground: panel.foreground
        placeholderText: root.config.socksUsername !== "" ? "User  " + root.config.socksUsername : "User (none)"
        onAccepted: { if (text.trim() !== "") vpn.setConfig("socksUsername", text.trim()); text = ""; panel.keyCatcherFocus() }
        Keys.onEscapePressed: { text = ""; panel.keyCatcherFocus() }
      }

      TextField {
        id: passField
        Layout.fillWidth: true
        foreground: panel.foreground
        password: true
        placeholderText: "Password"
        onAccepted: { if (text !== "") vpn.setConfig("socksPassword", text); text = ""; panel.keyCatcherFocus() }
        Keys.onEscapePressed: { text = ""; panel.keyCatcherFocus() }
      }

      PanelActionButton {
        visible: root.config.socksUsername !== ""
        iconText: "󰅖"
        tooltipText: "Clear SOCKS auth"
        foreground: panel.dim
        hoverColor: panel.urgent
        fontFamily: panel.fontFamily
        onClicked: vpn.setConfig("socksAuth", "clear")
      }
    }
  }

  PanelSectionHeader {
    text: "DNS"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  TextField {
    id: dnsField
    width: parent.width
    foreground: panel.foreground
    placeholderText: root.config.dns === "default" ? "AdGuard DNS (default)" : root.config.dns
    onAccepted: { vpn.setConfig("dns", text.trim() === "" ? "default" : text.trim()); text = ""; panel.keyCatcherFocus() }
    Keys.onEscapePressed: { text = ""; panel.keyCatcherFocus() }
  }

  Toggle {
    width: parent.width
    label: "Use VPN DNS system-wide"
    description: "Change the system resolver while connected"
    checked: root.config.changeSystemDns
    hasCursor: root.hasCursor("changeSystemDns")
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    onHovered: function(on) { if (on) root.setCursor("changeSystemDns") }
    onClicked: vpn.setConfig("changeSystemDns", !root.config.changeSystemDns)
  }

  PanelSectionHeader {
    text: "AEGIS"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  Toggle {
    width: parent.width
    label: "Reconnect at login"
    description: "If the VPN was on when the session ended, including crashes"
    checked: vpn ? vpn.autoConnect : true
    hasCursor: root.hasCursor("autoConnect")
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    onHovered: function(on) { if (on) root.setCursor("autoConnect") }
    onClicked: panel.persistSettings({ autoConnect: !vpn.autoConnect })
  }

  Toggle {
    width: parent.width
    label: "Locate home"
    description: "Ask ipinfo.io where you are while the VPN is off, to place you on the map"
    checked: vpn ? vpn.locateHome : true
    hasCursor: root.hasCursor("locateHome")
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    onHovered: function(on) { if (on) root.setCursor("locateHome") }
    onClicked: vpn.setLocateHome(!vpn.locateHome)
  }

  Toggle {
    width: parent.width
    label: "Colour map dots by ping"
    description: "Tint each city's nearest dot with its ping tier"
    checked: vpn ? vpn.pingDots : true
    hasCursor: root.hasCursor("pingDots")
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    onHovered: function(on) { if (on) root.setCursor("pingDots") }
    onClicked: panel.persistSettings({ pingDots: !vpn.pingDots })
  }

  // One prerequisite: what it is, where it stands, and the button that
  // moves it along — the same row the CLI update check always had.
  component SetupRow: CursorSurface {
    id: setupRow
    property string name: ""
    property string label: ""
    property string status: ""
    property bool statusHot: false
    property string buttonText: ""
    property string buttonIcon: ""
    property bool buttonVisible: true
    property bool spinning: false

    width: parent.width
    implicitHeight: Style.spacing.popupRowHeight + Style.space(6)
    hasCursor: root.hasCursor(name)
    foreground: panel.foreground
    fill: panel.hoverFill

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: setupRow.label
        color: panel.foreground
        font.family: panel.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        Layout.fillWidth: true
      }

      Text {
        textFormat: Text.PlainText
        text: setupRow.status
        color: setupRow.statusHot ? panel.glow : panel.dim
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
        Layout.maximumWidth: setupRow.width * 0.45
      }

      Button {
        visible: setupRow.buttonVisible
        text: setupRow.buttonText
        iconText: setupRow.buttonIcon
        iconSpinning: setupRow.spinning
        bordered: true
        foreground: panel.foreground
        fontFamily: panel.fontFamily
        fontSize: Style.font.caption
        onClicked: root.activate(root.targets.indexOf(setupRow.name))
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      z: -1
      onEntered: root.setCursor(setupRow.name)
    }
  }

  component ChipRow: Item {
    id: chipRow
    property string label: ""
    property var options: []
    property string value: ""
    property string cursorName: ""
    signal picked(string value)

    width: parent.width
    implicitHeight: Math.max(chipLabel.implicitHeight, chips.implicitHeight)

    Text {
      id: chipLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: chipRow.label
      color: root.hasCursor(chipRow.cursorName) ? panel.foreground : panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.body
    }

    ButtonGroup {
      id: chips
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      options: chipRow.options
      value: chipRow.value
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      fontSize: Style.font.caption
      focusable: false
      cursorIndex: root.hasCursor(chipRow.cursorName) ? selectedOptionIndex() : -1
      onHovered: function(index, on) { if (on) root.setCursor(chipRow.cursorName) }
      onChanged: function(v) { chipRow.picked(v) }
    }
  }
}
