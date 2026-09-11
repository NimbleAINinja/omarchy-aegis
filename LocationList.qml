import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Search field + ping-sorted location rows, favorites pinned first.
// Activating a row connects immediately.
Column {
  id: root
  property var panel: null
  property var vpn: null

  readonly property var rows: panel ? panel.visibleLocations : []
  readonly property int count: rows.length
  readonly property bool editing: search.activeFocus
  readonly property int favoriteCount: {
    var n = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].favorite) n++
    return n
  }

  spacing: Style.space(6)

  // The ListView is backed by a ListModel kept in step with `rows` rather than
  // by `rows` itself: assigning a JS array to `model` resets the view, which
  // destroys and rebuilds every visible delegate — ~11 rows of layout, text,
  // tooltip and animation — on every keystroke in the search field and every
  // location snapshot, however little actually changed. Model.diffRows says
  // what changed; remove/insert/set leave the untouched delegates alone.
  //
  // The model must always hold exactly `rows`, in order: the keyboard cursor
  // (panel.cursorIndex) is an index into it, and diffRows' tests pin that down.
  // dynamicRoles is what lets one role carry the whole location object with its
  // nulls intact (pingMs, lat, lon) instead of ListModel inferring a type per
  // field from whichever row happened to land first.
  ListModel { id: rowModel; dynamicRoles: true }
  // What rowModel currently holds, to diff the next `rows` against.
  property var modelRows: []

  function syncRows() {
    var next = Model.toList(root.rows)
    var ops = Model.diffRows(modelRows, next, Model.locationKey)
    for (var i = 0; i < ops.length; i++) {
      var op = ops[i]
      if (op.op === "reset") {
        rowModel.clear()
        for (var j = 0; j < op.rows.length; j++) rowModel.append({ entry: op.rows[j] })
      } else if (op.op === "remove") rowModel.remove(op.index, op.count)
      else if (op.op === "insert") rowModel.insert(op.index, { entry: op.row })
      else if (op.op === "set") rowModel.set(op.index, { entry: op.row })
    }
    modelRows = next
  }

  onRowsChanged: syncRows()
  Component.onCompleted: syncRows()

  function activate(index) {
    if (index < 0 || index >= rows.length) return
    var loc = rows[index]
    if (vpn.connected && loc.city === vpn.location) return
    panel.connectTo(loc)
  }

  function favoriteAt(index) {
    if (index < 0 || index >= rows.length) return
    panel.toggleFavorite(rows[index])
  }

  function focusSearch(seed) {
    if (seed && seed.length === 1 && /[a-z0-9 ]/i.test(seed)) search.text = search.text + seed
    search.forceActiveFocus()
    search.cursorPosition = search.text.length
  }

  function ensureVisible(index) {
    if (index >= 0 && index < list.count) list.positionViewAtIndex(index, ListView.Contain)
  }

  TextField {
    id: search
    width: parent.width
    foreground: panel.foreground
    placeholderText: "Search locations"
    text: panel.query
    onTextChanged: {
      panel.query = text
      panel.cursorIndex = 0
      if (text !== "") { panel.cursorActive = true; panel.focusSection = "list" }
    }
    onAccepted: { root.activate(panel.cursorIndex); panel.keyCatcherFocus() }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Down) { panel.setListCursor(Math.min(root.count - 1, panel.cursorIndex + 1)); root.ensureVisible(panel.cursorIndex); event.accepted = true }
      else if (event.key === Qt.Key_Up) { panel.setListCursor(Math.max(0, panel.cursorIndex - 1)); root.ensureVisible(panel.cursorIndex); event.accepted = true }
      else if (event.key === Qt.Key_Escape) {
        text = ""
        panel.keyCatcherFocus()
        event.accepted = true
      }
    }
  }

  Text {
    visible: root.count === 0
    width: parent.width
    text: !vpn || vpn.locations.length === 0 ? (!vpn || vpn.installed ? "Loading locations" : "adguardvpn-cli not found") : "No match"
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignHCenter
    topPadding: Style.space(8)
    bottomPadding: Style.space(8)
  }

  ListView {
    id: list
    visible: root.count > 0
    width: parent.width
    height: Math.min(contentHeight, Style.space(300))
    spacing: Style.space(2)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    model: rowModel
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    // `entry` is rowModel's one role; the name avoids colliding with
    // LocationRow's own `loc` property and its `row` id.
    delegate: LocationRow {
      required property var entry
      required property int index
      width: list.width
      loc: entry
      rowIndex: index
    }
  }

  component LocationRow: CursorSurface {
    id: row
    property var loc: null
    property int rowIndex: 0
    readonly property bool isCurrent: !!(loc && vpn && vpn.connected && loc.city === vpn.location)
    readonly property bool isPending: !!(loc && vpn && vpn.pendingLocation !== "" && loc.city === vpn.pendingLocation)
    readonly property string tier: Model.pingTier(loc ? loc.pingMs : null)
    readonly property color tierColor: tier === "good" ? panel.glow
      : (tier === "ok" ? Util.alpha(panel.foreground, 0.6)
      : (tier === "poor" ? panel.urgent : Util.alpha(panel.foreground, 0.25)))
    readonly property bool lastFavorite: loc && loc.favorite && rowIndex === root.favoriteCount - 1
    readonly property bool starred: Model.isFavorite(panel.favorites, loc)

    hasCursor: panel.cursorActive && panel.focusSection === "list" && panel.cursorIndex === rowIndex
    current: isCurrent || isPending
    foreground: panel.foreground
    fill: panel.hoverFill
    currentFill: panel.selectedFill
    // Fixed height: the star is always laid out (faded, not hidden) so hovering
    // never changes the row's geometry and the text stays put.
    implicitHeight: Style.spacing.popupRowHeight

    RowLayout {
      id: inner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: row.loc ? row.loc.iso : ""
        color: row.isCurrent ? panel.glow : panel.dim
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 0.5
        Layout.preferredWidth: Style.space(24)
      }

      Text {
        textFormat: Text.PlainText
        text: row.loc ? row.loc.city : ""
        color: panel.foreground
        font.family: panel.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.isCurrent
        elide: Text.ElideRight
        Layout.maximumWidth: inner.width * 0.45
      }

      Text {
        textFormat: Text.PlainText
        text: row.loc ? row.loc.country + (row.loc.virtual ? " · virtual" : "") : ""
        color: panel.dim
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.fillWidth: true
      }

      PanelActionButton {
        id: star
        readonly property bool shown: row.starred || row.hasCursor
        opacity: shown ? 1 : 0
        enabled: shown
        iconText: row.starred ? "󰓎" : "󰓒"
        tooltipText: row.starred ? "Unfavorite (f)" : "Favorite (f)"
        foreground: row.starred ? panel.glow : panel.dim
        hoverColor: panel.glow
        fontFamily: panel.fontFamily
        fontSize: Style.font.bodySmall
        size: Style.space(20)
        onClicked: panel.toggleFavorite(row.loc)
      }

      Text {
        textFormat: Text.PlainText
        text: row.loc && row.loc.pingMs !== null ? row.loc.pingMs + " ms" : ""
        color: panel.dim
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Style.space(46)
      }

      Item {
        Layout.preferredWidth: Style.space(10)
        Layout.preferredHeight: Style.space(10)
        Rectangle {
          anchors.centerIn: parent
          width: Style.space(6)
          height: width
          radius: width / 2
          color: row.tierColor
          visible: !row.isPending
        }
        Text {
          anchors.centerIn: parent
          visible: row.isPending
          text: "󰑐"
          color: panel.glow
          font.family: panel.fontFamily
          font.pixelSize: Style.font.caption
          NumberAnimation on rotation { running: row.isPending; from: 0; to: 360; duration: 900; loops: Animation.Infinite }
        }
      }
    }

    // Hairline under the last favorite so the pinned block reads as a group.
    Rectangle {
      visible: row.lastFavorite
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.bottomMargin: -Style.space(2)
      height: 1
      color: Util.alpha(panel.foreground, 0.08)
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: panel.setListCursor(row.rowIndex)
      onClicked: root.activate(row.rowIndex)
      z: -1
    }

    PanelToolTip {
      visible: mouse.containsMouse && !star.shown
      text: row.isCurrent ? "Connected" : "Connect"
      fontFamily: panel.fontFamily
    }
  }
}
