import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Kill switch: arm it, pick the apps to close when the tunnel drops, and
// optionally close them on your own disconnects too.
Column {
  id: root
  property var panel: null
  property var vpn: null

  readonly property bool armed: vpn ? vpn.killSwitch : false
  // Keyboard cursor targets, top to bottom; the on-disconnect toggle only
  // exists while armed. The apps field is reached by mouse.
  readonly property var targets: armed ? ["killSwitch", "killOnDisconnect"] : ["killSwitch"]
  readonly property int count: targets.length
  readonly property bool editing: appsField.activeFocus

  spacing: Style.space(8)

  function hasCursor(name) {
    return panel.cursorActive && panel.focusSection === "list" && targets[panel.cursorIndex] === name
  }

  function setCursor(name) {
    var i = targets.indexOf(name)
    if (i !== -1) panel.setListCursor(i)
  }

  function activate(index) {
    var name = targets[index]
    if (name === "killSwitch") {
      var on = !armed
      panel.persistSettings({ killSwitch: on })
      if (on) Qt.callLater(function() { appsField.forceActiveFocus() })
    } else if (name === "killOnDisconnect") {
      panel.persistSettings({ killOnDisconnect: !vpn.killOnDisconnect })
    }
  }

  PanelSectionHeader {
    text: "KILL SWITCH"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  Toggle {
    width: parent.width
    label: "Kill switch"
    description: "Close listed apps if the tunnel drops"
    checked: vpn ? vpn.killSwitch : false
    hasCursor: root.hasCursor("killSwitch")
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    onHovered: function(on) { if (on) root.setCursor("killSwitch") }
    onClicked: root.activate(root.targets.indexOf("killSwitch"))
  }

  Toggle {
    visible: root.armed
    width: parent.width
    label: "Also on disconnect"
    description: "Close them when you disconnect or log out too, not just on drops"
    checked: vpn ? vpn.killOnDisconnect : false
    hasCursor: root.hasCursor("killOnDisconnect")
    foreground: panel.foreground
    fontFamily: panel.fontFamily
    onHovered: function(on) { if (on) root.setCursor("killOnDisconnect") }
    onClicked: root.activate(root.targets.indexOf("killOnDisconnect"))
  }

  Column {
    visible: vpn ? vpn.killSwitch : false
    width: parent.width
    spacing: Style.space(6)

    // Chosen apps as chips; each is killed by exact process name.
    Flow {
      width: parent.width
      spacing: Style.space(6)
      visible: vpn && vpn.killApps.length > 0

      Repeater {
        model: vpn ? vpn.killApps : []
        BorderSurface {
          required property var modelData
          implicitWidth: chipRowLayout.implicitWidth + Style.space(8)
          implicitHeight: Style.space(24)
          color: "transparent"
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", panel.foreground, panel.accent)

          RowLayout {
            id: chipRowLayout
            anchors.centerIn: parent
            spacing: Style.space(2)
            Text {
              textFormat: Text.PlainText
              text: modelData
              color: panel.foreground
              font.family: panel.fontFamily
              font.pixelSize: Style.font.caption
              leftPadding: Style.space(4)
            }
            PanelActionButton {
              iconText: "󰅖"
              foreground: panel.dim
              hoverColor: panel.urgent
              fontFamily: panel.fontFamily
              fontSize: Style.font.caption
              size: Style.space(18)
              onClicked: panel.persistSettings({ killApps: Model.formatAppList(Model.removeApp(vpn.killApps, modelData)) })
            }
          }
        }
      }
    }

    TextField {
      id: appsField
      width: parent.width
      foreground: panel.foreground
      placeholderText: "Add a running app, e.g. firefox"
      property int suggestIndex: 0
      readonly property var suggestions: vpn ? Model.filterProcs(vpn.procs, text, vpn.killApps, 6) : []
      onTextChanged: suggestIndex = 0
      onActiveFocusChanged: if (activeFocus && vpn) vpn.refreshProcs()
      function acceptSuggestion() {
        var name = suggestions.length > 0 ? suggestions[Math.min(suggestIndex, suggestions.length - 1)] : text.trim()
        if (name === "") return
        panel.persistSettings({ killApps: Model.formatAppList(Model.addApp(vpn.killApps, name)) })
        text = ""
      }
      onAccepted: acceptSuggestion()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Tab) { acceptSuggestion(); event.accepted = true }
        else if (event.key === Qt.Key_Down) { suggestIndex = Math.min(suggestions.length - 1, suggestIndex + 1); event.accepted = true }
        else if (event.key === Qt.Key_Up) { suggestIndex = Math.max(0, suggestIndex - 1); event.accepted = true }
        else if (event.key === Qt.Key_Escape) { text = ""; panel.keyCatcherFocus(); event.accepted = true }
      }
    }

    // Suggestions from your running processes; Tab or Enter adds the highlighted one.
    Column {
      width: parent.width
      visible: appsField.activeFocus && appsField.suggestions.length > 0

      Repeater {
        model: appsField.suggestions
        CursorSurface {
          required property var modelData
          required property int index
          width: parent.width
          implicitHeight: Style.spacing.popupRowHeight
          hasCursor: appsField.suggestIndex === index
          foreground: panel.foreground
          fill: panel.hoverFill

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData
            color: panel.foreground
            font.family: panel.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: appsField.suggestIndex = index
            onClicked: { appsField.suggestIndex = index; appsField.acceptSuggestion(); appsField.forceActiveFocus() }
          }
        }
      }
    }
  }


  Text {
    visible: !root.armed
    width: parent.width
    text: "When armed, the apps listed here are closed the moment the tunnel drops unexpectedly, and you get a notification. You can also have them closed when you disconnect yourself."
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
