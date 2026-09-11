import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Traffic: what the tunnel is actually carrying, now and for the last couple
// of minutes. The numbers are the hero's own live rates; the graph is the
// window of samples Service keeps while the tunnel is up (TrafficGraph.qml).
Column {
  id: root
  property var panel: null
  property var vpn: null

  // The view has no rows of its own: the keyboard cursor steps from the
  // header straight to the footer, and nothing here is editable. Both are
  // still declared, because Panel asks every view for them.
  readonly property int count: 0
  readonly property bool editing: false

  readonly property var rates: vpn ? vpn.rates : ({ down: 0, up: 0 })
  // What the graph is showing: the same object it scaled its dots from, so
  // the legend's peaks and the columns can never disagree.
  readonly property var sampleWindow: graph.columns
  readonly property string peakText: sampleWindow.peakDown > 0 || sampleWindow.peakUp > 0
    ? "peak ↓" + Model.formatRate(sampleWindow.peakDown) + "/s ↑" + Model.formatRate(sampleWindow.peakUp) + "/s" : ""
  readonly property string caption: {
    if (!vpn || !vpn.connected) return "Not connected"
    var span = graph.columnCount + " s window"
    return vpn.iface !== "" ? vpn.iface + " · one column a second · " + span : "one column a second · " + span
  }

  spacing: Style.space(8)

  PanelSectionHeader {
    text: "TRAFFIC"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  // Live rates on the left in the two colours the graph's halves use, the
  // window's peaks on the right.
  Item {
    width: parent.width
    implicitHeight: Math.max(live.implicitHeight, peak.implicitHeight)

    Row {
      id: live
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: "↓" + Model.formatRate(root.rates.down) + "/s"
        color: panel.glow
        font.family: panel.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        textFormat: Text.PlainText
        text: "↑" + Model.formatRate(root.rates.up) + "/s"
        color: Util.alpha(panel.foreground, 0.7)
        font.family: panel.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Text {
      id: peak
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.peakText
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  TrafficGraph {
    id: graph
    width: parent.width
    height: implicitHeight
    // The map's lattice, so the two read as one surface.
    dotPitch: Style.space(4)
    dotsPerHalf: 12
    floorRate: Model.TRAFFIC_FLOOR
    history: vpn ? vpn.trafficHistory : []
    centerColor: Util.alpha(panel.foreground, 0.22)
    upColor: Util.alpha(panel.foreground, 0.7)
    downColor: panel.glow
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: root.caption
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
