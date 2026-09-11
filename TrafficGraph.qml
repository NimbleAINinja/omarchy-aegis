import QtQuick
import "Model.js" as Model

// Dot-matrix throughput graph, in the same idiom as the map: one column of
// dots per rate sample, the newest column at the right edge and older ones
// marching left, with sent growing up from a dim centre line and received
// growing down. Each half scales to its own peak over the window it shows
// (Model.trafficColumns), so a quiet tunnel and a busy one both fill the
// height and the shape, not the size, is what carries the reading.
//
// Imports nothing but QtQuick and Model.js, and every paint routine takes the
// 2D context as a parameter, so the whole thing can be rendered headlessly and
// its paints exercised with a fake context — the same deal WorldMap.qml makes.
Item {
  id: root

  // [{ down, up }] in bytes/second, oldest first — Service.trafficHistory.
  property var history: []
  property real dotPitch: 4
  property real dotFill: 0.55
  // Rows per half, so the graph is this many dots up and the same down.
  property int dotsPerHalf: 12
  // The smallest scale a half is drawn at; below it everything would read as
  // a burst. See Model.TRAFFIC_FLOOR.
  property real floorRate: 1024

  property color centerColor: Qt.rgba(1, 1, 1, 0.22)
  property color upColor: "white"
  property color downColor: "white"

  // As many whole columns as fit, and they are laid out from the right edge
  // back: the newest sample is the one the eye starts on.
  readonly property int columnCount: dotPitch > 0 ? Math.max(0, Math.floor(width / dotPitch)) : 0
  readonly property var columns: Model.trafficColumns(history, columnCount, dotsPerHalf, floorRate)
  readonly property int rowCount: dotsPerHalf * 2 + 1

  implicitHeight: Math.round(rowCount * dotPitch)

  readonly property real offsetX: width - columnCount * dotPitch
  readonly property real offsetY: (height - rowCount * dotPitch) / 2
  // Row `dotsPerHalf` of the lattice: the centre line both halves grow from.
  readonly property real centerY: rowY(dotsPerHalf)

  function columnX(index) { return offsetX + (index + 0.5) * dotPitch }
  function rowY(index) { return offsetY + (index + 0.5) * dotPitch }

  // Square dots on the lattice, exactly as the map's land dots are drawn, so
  // the two read as one family. Never smaller than 2 px: at a 4 px pitch a
  // single-pixel dot all but disappears against the popup background.
  function dotSide() { return Math.max(2, Math.round(dotPitch * dotFill)) }

  function paintDot(ctx, cx, cy, side) {
    ctx.fillRect(Math.round(cx - side / 2), Math.round(cy - side / 2), side, side)
  }

  // The centre line is a row of dim dots rather than a stroke: a hairline
  // would be the only non-dot mark on the whole graph.
  function paintCenter(ctx) {
    var count = columnCount
    if (count === 0) return
    var side = dotSide()
    ctx.fillStyle = centerColor
    for (var i = 0; i < count; i++) paintDot(ctx, columnX(i), centerY, side)
  }

  // `direction` is -1 for the half above the centre and 1 for the one below.
  // One fill style for the whole half, set only if it actually has a dot.
  function paintHalf(ctx, counts, color, direction) {
    var list = counts || []
    var side = dotSide()
    var painted = false
    for (var i = 0; i < list.length; i++) {
      var dots = list[i]
      if (dots <= 0) continue
      if (!painted) { ctx.fillStyle = color; painted = true }
      var x = columnX(i)
      // Growing out from the centre, one row at a time, so a column is a bar
      // and not a scatter.
      for (var row = 1; row <= dots; row++) paintDot(ctx, x, rowY(dotsPerHalf + direction * row), side)
    }
  }

  function paintGraph(ctx) {
    paintCenter(ctx)
    paintHalf(ctx, columns.up, upColor, -1)
    paintHalf(ctx, columns.down, downColor, 1)
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onAvailableChanged: if (available) requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      if (!ctx) return
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      root.paintGraph(ctx)
    }
  }

  // A sample lands once a second while the tab is up, so this is the one
  // thing that repaints often; everything else here only moves on a resize or
  // a theme change.
  onColumnsChanged: canvas.requestPaint()
  // A width change reaches the paint through columnCount; a height change
  // only moves the lattice, so it needs saying.
  onHeightChanged: canvas.requestPaint()
  onCenterColorChanged: canvas.requestPaint()
  onUpColorChanged: canvas.requestPaint()
  onDownColorChanged: canvas.requestPaint()
  onDotFillChanged: canvas.requestPaint()
}
