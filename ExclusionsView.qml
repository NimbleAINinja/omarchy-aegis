import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Site exclusions: mode chips, domain rows with remove, add field.
Column {
  id: root
  property var panel: null
  property var vpn: null

  readonly property var rows: vpn ? vpn.exclusionRows : []
  readonly property int count: rows.length
  readonly property bool editing: addField.activeFocus

  spacing: Style.space(8)

  function activate(index) { pauseAt(index) }
  function pauseAt(index) {
    if (index < 0 || index >= rows.length) return
    vpn.setExclusionPaused(rows[index].domain, !rows[index].paused)
  }
  function removeAt(index) {
    if (index < 0 || index >= rows.length) return
    vpn.forgetExclusion(rows[index].domain)
  }
  function moveHorizontal(dx) {
    vpn.setExclusionMode(vpn.exclusions.mode === "general" ? "selective" : "general")
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(sectionTitle.implicitHeight, modes.implicitHeight)

    PanelSectionHeader {
      id: sectionTitle
      text: "EXCLUSIONS"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    ButtonGroup {
      id: modes
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      options: [
        { value: "general", label: "General", tooltip: "VPN for everything except these sites" },
        { value: "selective", label: "Selective", tooltip: "VPN only for these sites" }
      ]
      value: vpn ? vpn.exclusions.mode : "general"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      fontSize: Style.font.caption
      focusable: false
      onChanged: function(value) { vpn.setExclusionMode(value) }
    }
  }

  Text {
    visible: root.count === 0
    width: parent.width
    text: !vpn || vpn.exclusions.mode === "general" ? "Every site goes through the VPN" : "No site goes through the VPN"
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignHCenter
    topPadding: Style.space(6)
    bottomPadding: Style.space(6)
  }

  Column {
    width: parent.width
    spacing: Style.space(2)

    Repeater {
      model: root.rows
      CursorSurface {
        id: row
        required property var modelData
        required property int index
        readonly property bool paused: modelData.paused === true
        width: parent.width
        hasCursor: panel.cursorActive && panel.focusSection === "list" && panel.cursorIndex === index
        foreground: panel.foreground
        fill: panel.hoverFill
        implicitHeight: Style.spacing.popupRowHeight

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(4)
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: row.modelData.domain
            color: row.paused ? panel.dim : panel.foreground
            font.family: panel.fontFamily
            font.pixelSize: Style.font.body
            font.strikeout: row.paused
            elide: Text.ElideMiddle
            Layout.fillWidth: true
          }

          Text {
            visible: row.paused
            textFormat: Text.PlainText
            text: "paused"
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelActionButton {
            iconText: row.paused ? "󰐊" : "󰏤"
            tooltipText: row.paused ? "Resume (p)" : "Pause (p)"
            foreground: panel.dim
            hoverColor: panel.glow
            fontFamily: panel.fontFamily
            onClicked: vpn.setExclusionPaused(row.modelData.domain, !row.paused)
          }

          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Remove (x)"
            foreground: panel.dim
            hoverColor: panel.urgent
            fontFamily: panel.fontFamily
            onClicked: vpn.forgetExclusion(row.modelData.domain)
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          z: -1
          onEntered: panel.setListCursor(row.index)
        }
      }
    }
  }

  TextField {
    id: addField
    width: parent.width
    foreground: panel.foreground
    placeholderText: "Add domain"
    onAccepted: {
      vpn.addExclusion(text)
      text = ""
    }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) { text = ""; panel.keyCatcherFocus(); event.accepted = true }
    }
  }
}
