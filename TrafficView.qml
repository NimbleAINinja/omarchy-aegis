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

  // What the graph is showing: the same object it scaled its dots from, so
  // the legend's peaks and the columns can never disagree. The live rates are
  // not repeated here — the hero above already prints them.
  readonly property var sampleWindow: graph.columns
  readonly property string peakText: sampleWindow.peakDown > 0 || sampleWindow.peakUp > 0
    ? "peak ↓ " + Model.formatRate(sampleWindow.peakDown) + "/s ↑ " + Model.formatRate(sampleWindow.peakUp) + "/s" : ""

  spacing: Style.space(8)

  PanelSectionHeader {
    text: "TRAFFIC"
    foreground: panel.foreground
    fontFamily: panel.fontFamily
  }

  // The window's peaks, hard against the right edge so the text grows
  // leftward as digits come and go; the row folds away while there is
  // nothing to report (no tunnel, or one that has not moved a byte yet).
  Text {
    id: peak
    textFormat: Text.PlainText
    visible: root.peakText !== ""
    width: parent.width
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideNone
    text: root.peakText
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
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
