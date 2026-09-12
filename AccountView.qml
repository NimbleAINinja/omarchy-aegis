import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Account: who is signed in and the one action that applies.
Column {
  id: root
  property var panel: null
  property var vpn: null

  readonly property var account: vpn ? vpn.account : ({ loggedIn: false })
  // "in" / "out" / "unknown": with no CLI the account call never lands, and
  // account.loggedIn's placeholder would show an empty card and a Log out.
  readonly property string state: Model.accountState(vpn ? vpn.account : null, vpn ? vpn.accountLoaded : false)
  // "logout" / "login" / "": the hero above already offers the log-in when
  // that is the setup step, so the tab doesn't repeat it. See accountAction.
  readonly property string action: Model.accountAction(root.state, panel ? panel.setupStep : "")
  // No button, no row for the cursor to sit on.
  readonly property int count: action === "" ? 0 : 1
  readonly property bool editing: false
  readonly property bool hasCursor: panel.cursorActive && panel.focusSection === "list" && panel.cursorIndex === 0

  spacing: Style.space(10)

  function activate(index) { root.action === "logout" ? vpn.logout() : (root.action === "login" ? vpn.login() : null) }

  PanelSectionHeader {
    text: "ACCOUNT"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  Column {
    visible: root.state === "in"
    width: parent.width
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.account.email
      color: panel.foreground
      font.family: panel.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideMiddle
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var parts = []
        if (root.account.plan) parts.push(root.account.plan.charAt(0) + root.account.plan.slice(1).toLowerCase())
        if (root.account.devices !== null) parts.push(root.account.devices + " devices")
        if (root.account.validUntil) parts.push("until " + root.account.validUntil)
        return parts.join(" · ")
      }
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Text {
    visible: root.state !== "in"
    width: parent.width
    text: root.state === "out" ? "Not signed in" : "Not checked"
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.body
  }

  Button {
    visible: root.action !== ""
    text: root.action === "logout" ? "Log out" : "Log in"
    iconText: root.action === "logout" ? "󰍃" : "󰍂"
    bordered: true
    hasCursor: root.hasCursor
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    fontSize: Style.font.bodySmall
    onHovered: function(on) { if (on) panel.setListCursor(0) }
    onClicked: root.activate(0)
  }
}
