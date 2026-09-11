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

  // With no tunnel there is nothing to measure, and the legend says so by
  // reading zero in the dim colour over an empty graph — one line fewer than
  // a caption underneath saying the same thing in words.
  readonly property bool live: vpn ? vpn.connected === true : false
  readonly property var rates: live && vpn.rates ? vpn.rates : ({ down: 0, up: 0 })
  // What the graph is showing: the same object it scaled its dots from, so
  // the legend's peaks and the columns can never disagree.
  readonly property var sampleWindow: graph.columns
  readonly property string peakText: sampleWindow.peakDown > 0 || sampleWindow.peakUp > 0
    ? "peak ↓ " + Model.formatRate(sampleWindow.peakDown) + "/s ↑ " + Model.formatRate(sampleWindow.peakUp) + "/s" : ""
  // Wide enough for the longest rate the formatter can produce ("↓ 1023/s"),
  // which is what keeps the two of them from sliding about; see below.
  readonly property real rateWidth: Style.space(96)

  spacing: Style.space(8)

  PanelSectionHeader {
    text: "TRAFFIC"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  // Live rates on the left in the two colours the graph's halves use, the
  // window's peaks on the right. Each rate owns a fixed slot rather than
  // being packed against its neighbour: the text is as narrow as "↑ 0/s" and
  // as wide as "↑ 1023/s", so with the two of them in a Row the up-rate hopped
  // sideways every time the down-rate gained or lost a digit — once a second,
  // right next to a graph whose whole job is to sit still and be read.
  Item {
    width: parent.width
    implicitHeight: Math.max(downRate.implicitHeight, upRate.implicitHeight, peak.implicitHeight)

    Text {
      id: downRate
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.rateWidth
      horizontalAlignment: Text.AlignLeft
      elide: Text.ElideNone
      text: "↓ " + Model.formatRate(root.rates.down) + "/s"
      color: root.live ? panel.glow : panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: upRate
      textFormat: Text.PlainText
      anchors.left: downRate.right
      anchors.verticalCenter: parent.verticalCenter
      width: root.rateWidth
      horizontalAlignment: Text.AlignLeft
      elide: Text.ElideNone
      text: "↑ " + Model.formatRate(root.rates.up) + "/s"
      color: root.live ? Util.alpha(panel.foreground, 0.7) : panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.body
    }

    // Whatever the two slots leave, with the text hard against the right edge,
    // so it grows leftward into the gap instead of pushing anything.
    Text {
      id: peak
      textFormat: Text.PlainText
      anchors.left: upRate.right
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideNone
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
    // The same hairline the separators are drawn with, so the axis belongs to
    // the panel's chrome rather than to the data.
    centerColor: Util.alpha(panel.foreground, 0.12)
    upColor: Util.alpha(panel.foreground, 0.7)
    downColor: panel.glow
  }
}
