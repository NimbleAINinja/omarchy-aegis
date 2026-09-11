import QtQuick
import QtTest
import "../.." as Plugin

// Headless checks for TrafficGraph.qml: the paint routine receives a recording
// fake 2D context, so no real Canvas surface is needed. Same pattern as
// tst_worldmap.qml.
TestCase {
  id: suite
  name: "TrafficGraph"
  width: 200
  height: 120

  function fakeContext() {
    var record = { rects: [], fillStyles: [], fills: 0 }
    return {
      record: record,
      set fillStyle(value) { record.fillStyles.push(value) },
      get fillStyle() { return record.fillStyles[record.fillStyles.length - 1] },
      fillRect: function(x, y, w, h) { record.rects.push({ x: x, y: y, w: w, h: h, style: record.fillStyles[record.fillStyles.length - 1] }) },
      beginPath: function() {},
      moveTo: function() {},
      lineTo: function() {},
      stroke: function() {},
      fill: function() { record.fills++ },
      clearRect: function() {},
      reset: function() {}
    }
  }

  Component {
    id: graphComponent
    Plugin.TrafficGraph {
      width: 120
      height: 100
      dotPitch: 4
      dotsPerHalf: 12
      floorRate: 1024
      centerColor: "#404040"
      upColor: "#00ff00"
      downColor: "#0000ff"
    }
  }

  function makeGraph(props) {
    var graph = createTemporaryObject(graphComponent, suite, props || {})
    verify(graph !== null)
    return graph
  }

  function styled(record, color) {
    var out = []
    for (var i = 0; i < record.rects.length; i++)
      if (String(record.rects[i].style) === String(color)) out.push(record.rects[i])
    return out
  }

  function test_geometry_is_a_lattice_of_whole_columns_and_rows() {
    var graph = makeGraph()
    compare(graph.columnCount, 30, "120 px at a 4 px pitch")
    compare(graph.rowCount, 25, "12 up, 12 down, one centre row")
    compare(graph.implicitHeight, 100)
    // The newest column touches the right edge; the centre row is the middle
    // of the lattice.
    fuzzyCompare(graph.columnX(graph.columnCount - 1), graph.width - graph.dotPitch / 2, 1e-6)
    fuzzyCompare(graph.centerY, graph.height / 2, 1e-6)
    fuzzyCompare(graph.rowY(0), graph.centerY - graph.dotsPerHalf * graph.dotPitch, 1e-6)
  }

  function test_an_empty_history_paints_the_centre_line_alone() {
    var graph = makeGraph()
    var ctx = fakeContext()
    graph.paintGraph(ctx)
    compare(ctx.record.rects.length, graph.columnCount, "one dim dot per column")
    compare(ctx.record.fillStyles.length, 1, "one fill style for the whole line")
    compare(String(ctx.record.fillStyles[0]), String(graph.centerColor))
    for (var i = 0; i < ctx.record.rects.length; i++) {
      var dot = ctx.record.rects[i]
      compare(dot.w, dot.h, "square")
      verify(dot.w >= 2, "a 1 px dot disappears against the background")
      fuzzyCompare(dot.y + dot.h / 2, graph.centerY, 1)
    }
  }

  function test_the_newest_sample_is_the_column_at_the_right_edge() {
    // One sample, and the history is far shorter than the width: everything
    // but the last column is empty.
    var graph = makeGraph({ history: [{ down: 1024, up: 1024 }] })
    var ctx = fakeContext()
    graph.paintGraph(ctx)
    var up = styled(ctx.record, graph.upColor)
    var down = styled(ctx.record, graph.downColor)
    compare(up.length, graph.dotsPerHalf, "a full column: the sample is the window's own peak")
    compare(down.length, graph.dotsPerHalf)
    var rightmost = graph.columnX(graph.columnCount - 1)
    for (var i = 0; i < up.length; i++) {
      fuzzyCompare(up[i].x + up[i].w / 2, rightmost, 1)
      verify(up[i].y < graph.centerY, "sent grows upward")
    }
    for (var k = 0; k < down.length; k++) {
      fuzzyCompare(down[k].x + down[k].w / 2, rightmost, 1)
      verify(down[k].y > graph.centerY, "received grows downward")
    }
    // Contiguous from the centre out, one row per dot, so a column is a bar.
    var ys = up.map(function(d) { return Math.round(d.y + d.h / 2) }).sort(function(a, b) { return a - b })
    for (var r = 1; r < ys.length; r++) compare(ys[r] - ys[r - 1], graph.dotPitch)
    fuzzyCompare(ys[ys.length - 1], graph.centerY - graph.dotPitch, 1)
  }

  function test_a_short_history_leaves_the_left_side_empty() {
    var history = []
    for (var i = 0; i < 5; i++) history.push({ down: 1024, up: 0 })
    var graph = makeGraph({ history: history })
    var ctx = fakeContext()
    graph.paintGraph(ctx)
    var down = styled(ctx.record, graph.downColor)
    compare(down.length, 5 * graph.dotsPerHalf, "five columns, no more")
    var firstColumn = graph.columnX(graph.columnCount - 5)
    for (var k = 0; k < down.length; k++)
      verify(down[k].x + down[k].w / 2 >= firstColumn - 1, "nothing on the left of the history")
    compare(styled(ctx.record, graph.upColor).length, 0, "an idle upload paints nothing")
  }

  function test_each_half_scales_to_its_own_peak_with_a_floor() {
    // Received peaks at 8x the floor, sent never leaves the floor: the two
    // halves must not rescale each other.
    var graph = makeGraph({ history: [{ down: 8 * 1024, up: 1024 }, { down: 1024, up: 512 }] })
    var ctx = fakeContext()
    graph.paintGraph(ctx)
    compare(graph.columns.maxDown, 8 * 1024)
    compare(graph.columns.maxUp, 1024, "the floor, not the download's peak")
    compare(graph.columns.down[graph.columnCount - 2], graph.dotsPerHalf)
    compare(graph.columns.down[graph.columnCount - 1], 2, "an eighth of the peak")
    compare(graph.columns.up[graph.columnCount - 2], graph.dotsPerHalf)
    compare(graph.columns.up[graph.columnCount - 1], 6)
    // And the paint follows the counts.
    compare(styled(ctx.record, graph.downColor).length, graph.dotsPerHalf + 2)
    compare(styled(ctx.record, graph.upColor).length, graph.dotsPerHalf + 6)
    // One fill style per half that has anything to draw, plus the centre line.
    compare(ctx.record.fillStyles.length, 3)
  }

  function test_the_two_halves_never_share_a_colour_or_a_row() {
    var graph = makeGraph({ history: [{ down: 4096, up: 4096 }] })
    verify(String(graph.upColor) !== String(graph.downColor), "sent and received are told apart by colour too")
    var ctx = fakeContext()
    graph.paintGraph(ctx)
    var rows = {}
    for (var i = 0; i < ctx.record.rects.length; i++) {
      var dot = ctx.record.rects[i]
      var key = Math.round(dot.y) + ":" + Math.round(dot.x)
      verify(rows[key] === undefined, "no two dots on the same lattice slot")
      rows[key] = String(dot.style)
    }
  }

  function test_a_resize_reflows_the_columns() {
    var graph = makeGraph({ history: [{ down: 1024, up: 0 }] })
    compare(graph.columnCount, 30)
    graph.width = 60
    compare(graph.columnCount, 15)
    var ctx = fakeContext()
    graph.paintGraph(ctx)
    // Still hard against the right edge after the reflow.
    var down = styled(ctx.record, graph.downColor)
    compare(down.length, graph.dotsPerHalf)
    fuzzyCompare(down[0].x + down[0].w / 2, graph.width - graph.dotPitch / 2, 1)
  }
}
