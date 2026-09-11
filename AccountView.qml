import QtQuick
import qs.Commons
import qs.Ui

// Account: who is signed in and the one action that applies.
Column {
  id: root
  property var panel: null
  property var vpn: null

  readonly property var account: vpn ? vpn.account : ({ loggedIn: false })
  readonly property int count: 1
  readonly property bool editing: false
  readonly property bool hasCursor: panel.cursorActive && panel.focusSection === "list" && panel.cursorIndex === 0

  spacing: Style.space(10)

  function activate(index) { account.loggedIn ? vpn.logout() : vpn.login() }

  PanelSectionHeader {
    text: "ACCOUNT"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  Column {
    visible: root.account.loggedIn
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
    visible: !root.account.loggedIn
    width: parent.width
    text: "Not signed in"
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.body
  }

  Button {
    text: root.account.loggedIn ? "Log out" : "Log in"
    iconText: root.account.loggedIn ? "󰍃" : "󰍂"
    bordered: true
    hasCursor: root.hasCursor
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    fontSize: Style.font.bodySmall
    onHovered: function(on) { if (on) panel.setListCursor(0) }
    onClicked: root.activate(0)
  }
}
