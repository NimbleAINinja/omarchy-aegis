import QtQuick
import QtTest
import "../.." as Plugin
import "../../Grid.js" as Grid

// Headless checks for WorldMap.qml: paint routines receive a recording fake
// 2D context, so no real Canvas surface is needed.
TestCase {
  id: suite
  name: "WorldMap"
  // Visible so synthesized pointer events (mouseMove/mouseClick) are delivered.
  visible: true
  width: 400
  height: 200
  when: windowShown

  function tinyGrid(landCol, landRow) {
    // 8 x 4 grid with exactly one land cell.
    var rle = []
    for (var r = 0; r < 4; r++) {
      if (r === landRow) rle.push([landCol, 1, 8 - landCol - 1])
      else rle.push([8])
    }
    return { cols: 8, rows: 4, rle: rle }
  }

  function fakeContext() {
    var record = { rects: [], fillStyles: [], strokeStyles: [], arcs: [], texts: [], quads: [], lines: [], starts: [], strokes: 0, fills: 0, moves: 0, measures: [] }
    return {
      record: record,
      font: "",
      lineWidth: 1,
      lineJoin: "miter",
      lineCap: "butt",
      textAlign: "left",
      textBaseline: "alphabetic",
      set fillStyle(value) { record.fillStyles.push(value) },
      get fillStyle() { return record.fillStyles[record.fillStyles.length - 1] },
      set strokeStyle(value) { record.strokeStyles.push(value) },
      get strokeStyle() { return record.strokeStyles[record.strokeStyles.length - 1] },
      fillRect: function(x, y, w, h) { record.rects.push({ x: x, y: y, w: w, h: h }) },
      beginPath: function() {},
      // `starts` is where each subpath begins: with dashes there is one per
      // dash, and where they begin is the whole point of the pattern.
      moveTo: function(x, y) { record.moves++; record.starts.push({ x: x, y: y }) },
      lineTo: function(x, y) { record.lines.push({ x: x, y: y }) },
      quadraticCurveTo: function(cx, cy, x, y) { record.quads.push({ cx: cx, cy: cy, x: x, y: y }) },
      arc: function(x, y, r) { record.arcs.push({ x: x, y: y, r: r }) },
      stroke: function() { record.strokes++ },
      fill: function() { record.fills++ },
      measureText: function(text) { record.measures.push(text); return { width: text.length * 6 } },
      strokeText: function() {},
      fillText: function(text, x, y) { record.texts.push({ text: text, x: x, y: y }) },
      clearRect: function() {},
      reset: function() {},
      save: function() {},
      restore: function() {},
      translate: function() {},
      scale: function() {},
      closePath: function() {}
    }
  }

  Component {
    id: mapComponent
    Plugin.WorldMap {
      width: 360
      height: 180
      dotPitch: 45
      latMin: -90
      latMax: 90
      animate: false
    }
  }

  function makeMap(props) {
    var map = createTemporaryObject(mapComponent, suite, props || {})
    verify(map !== null)
    return map
  }

  readonly property var paris: ({ lat: 48.86, lon: 2.35, label: "Paris" })
  readonly property var tokyo: ({ lat: 35.68, lon: 139.69, label: "Tokyo" })

  function test_projection() {
    var map = makeMap()
    compare(map.projectX(-180), 0)
    compare(map.projectX(0), map.width / 2)
    compare(map.projectX(180), map.width)
    compare(map.projectY(90), 0)
    compare(map.projectY(-90), map.height)
    fuzzyCompare(map.lonAt(map.width / 2), 0, 1e-9)
    fuzzyCompare(map.latAt(map.height / 2), 0, 1e-9)
    var p = map.pointFor(0, 0)
    compare(p.x, map.width / 2)
    compare(p.y, map.height / 2)
  }

  function test_dots_use_one_fill_style() {
    var map = makeMap()
    // Cell (col 6, row 1) of the 8x4 grid covers lon [90,135], lat [0,45];
    // with a 45px pitch on 360x180 the dot centres line up with grid cells.
    map.grid = Grid.decodeRle(tinyGrid(6, 1))
    map.rebuildCells()
    compare(map.cellX.length, 1)
    var ctx = fakeContext()
    map.paintDots(ctx)
    compare(ctx.record.rects.length, 1)
    compare(ctx.record.fillStyles.length, 1)
  }

  function test_link_none_paints_nothing() {
    var map = makeMap({ home: paris, exit: tokyo, linkState: "none" })
    var ctx = fakeContext()
    map.paintLink(ctx)
    compare(ctx.record.strokes, 0)
    compare(ctx.record.arcs.length, 0)
    compare(map.segments.length, 0)
  }

  function test_link_connected_strokes_curve_twice_with_beads() {
    var map = makeMap({ home: paris, exit: tokyo, linkState: "connected" })
    compare(map.drawProgress, 1)
    compare(map.segments.length, 1)
    var ctx = fakeContext()
    map.paintLink(ctx)
    // One trace, stroked twice: the path survives a stroke.
    compare(ctx.record.quads.length, 1)
    compare(ctx.record.strokes, 2)
    compare(ctx.record.lines.length, 0, "one solid curve, never dashes")
    compare(ctx.lineCap, "round")
    compare(ctx.record.arcs.length, 4)
    compare(ctx.record.fills, 4)
    // Fat translucent stroke under a thin bright one.
    verify(ctx.record.strokeStyles[0].indexOf("rgba(") === 0)
    verify(ctx.record.strokeStyles[0] !== ctx.record.strokeStyles[1])
    // Beads sit on the curve: their y is above the chord (the arc bows up).
    var chordY = Math.max(map.pointFor(paris.lat, paris.lon).y, map.pointFor(tokyo.lat, tokyo.lon).y)
    for (var i = 0; i < 4; i++) verify(ctx.record.arcs[i].y <= chordY + 0.001)
  }

  function test_link_connecting_draws_marching_dashes_without_beads() {
    // Qt's Canvas has no setLineDash, so a connecting link is a run of
    // polylines (Link.dashes) instead of one curve — and no beads: they only
    // ride a tunnel that is actually up.
    var map = makeMap({ home: paris, exit: tokyo, linkState: "connecting" })
    compare(map.drawProgress, 0)
    map.drawProgress = 0.5
    var ctx = fakeContext()
    map.paintLink(ctx)
    compare(ctx.record.quads.length, 0)
    compare(ctx.record.arcs.length, 0, "no beads while connecting")
    compare(ctx.record.fills, 0)
    verify(ctx.record.moves > 4, "one moveTo per dash: " + ctx.record.moves)
    verify(ctx.record.lines.length > ctx.record.moves, "each dash bends with the arc")
    compare(ctx.record.strokes, 2, "one trace of every dash, stroked halo then core")
    compare(ctx.lineCap, "butt", "round caps would close the gaps")
    // The dashes stop about halfway along the chord in x, where the draw-in has
    // got to, and there is a real gap between one dash and the next.
    var x0 = map.pointFor(paris.lat, paris.lon).x
    var x1 = map.pointFor(tokyo.lat, tokyo.lon).x
    var last = ctx.record.lines[ctx.record.lines.length - 1]
    verify(last.x > x0 + (x1 - x0) * 0.3)
    verify(last.x < x0 + (x1 - x0) * 0.7)
  }

  function test_connecting_dashes_march_with_the_phase() {
    var map = makeMap({ home: paris, exit: tokyo, linkState: "connecting" })
    // Fully drawn in: the pattern, not the draw-in, is what moves here.
    map.drawProgress = 1
    compare(map.dashPhase, 0)
    var still = fakeContext()
    map.paintLink(still)
    map.phase = 3
    verify(map.dashPhase > 0, "the phase walks the pattern along the arc")
    var moved = fakeContext()
    map.paintLink(moved)
    // The same pattern, shifted: one dash may fall off the end as another
    // appears at home, never more.
    verify(Math.abs(moved.record.moves - still.record.moves) <= 1)
    // Every dash begins further along the arc than it did.
    var a = still.record.starts[still.record.starts.length - 1]
    var b = moved.record.starts[moved.record.starts.length - 1]
    verify(Math.abs(b.x - a.x) > 0.01 || Math.abs(b.y - a.y) > 0.01, "the dashes moved")
    // One whole period on (20 phase units) the pattern repeats exactly.
    map.phase = 20
    compare(map.dashPhase, 0)
  }

  function test_link_state_transitions_reset_progress() {
    var map = makeMap({ home: paris, exit: tokyo, linkState: "connecting" })
    map.drawProgress = 0.4
    map.linkState = "connected"
    compare(map.drawProgress, 1)
    map.linkState = "none"
    compare(map.drawProgress, 0)
  }

  function test_link_across_pacific_is_one_interior_arc() {
    var la = { lat: 34.05, lon: -118.24, label: "Los Angeles" }
    var map = makeMap({ home: la, exit: tokyo, linkState: "connected" })
    compare(map.segments.length, 1)
    var ctx = fakeContext()
    map.paintLink(ctx)
    compare(ctx.record.quads.length, 1)
    compare(ctx.record.arcs.length, 4)
  }

  function test_hover_point_draws_a_ring_only_when_set() {
    var map = makeMap({ home: paris, exit: null, linkState: "none" })
    var ctx = fakeContext()
    map.paintMarkers(ctx)
    var before = ctx.record.arcs.length
    map.hover = { lat: 35.68, lon: 139.69 }
    var ctx2 = fakeContext()
    map.paintMarkers(ctx2)
    compare(ctx2.record.arcs.length, before + 2, "hover adds a ring and a dot")
    var p = map.pointFor(35.68, 139.69)
    var ring = ctx2.record.arcs[ctx2.record.arcs.length - 2]
    fuzzyCompare(ring.x, p.x, 0.01)
    fuzzyCompare(ring.y, p.y, 0.01)
    verify(ring.r > map.dotPitch, "ring is larger than a land dot")
    map.hover = null
    var ctx3 = fakeContext()
    map.paintMarkers(ctx3)
    compare(ctx3.record.arcs.length, before)
  }

  function test_candidates_pick_nearest_city_and_paint_its_label() {
    var map = makeMap({ home: paris, exit: null, linkState: "none" })
    map.candidates = [
      { city: "Tokyo", lat: 35.68, lon: 139.69 },
      { city: "Seoul", lat: 37.57, lon: 126.98 },
      { city: "NoCoords", lat: null, lon: null }
    ]
    var p = map.pointFor(35.68, 139.69)
    var picked = map.pickCandidate(p.x + 1, p.y + 1)
    compare(picked.city, "Tokyo")
    compare(map.pickCandidate(5, 5), null, "nothing near the corner")
    map.hoverCandidate = picked
    var ctx = fakeContext()
    map.paintMarkers(ctx)
    var labels = ctx.record.texts.map(function(t) { return t.text })
    verify(labels.indexOf("Tokyo") !== -1, "hovered candidate is labelled: " + labels.join(","))
    verify(ctx.record.arcs.length >= 2, "ring and dot drawn for the candidate")
    map.hoverCandidate = null
    var ctx2 = fakeContext()
    map.paintMarkers(ctx2)
    compare(ctx2.record.texts.map(function(t) { return t.text }).indexOf("Tokyo"), -1)
  }

  function test_mouse_hover_over_the_map_snaps_to_the_nearest_city_and_clicks_connect() {
    var map = makeMap({ home: paris, exit: null, linkState: "none" })
    map.candidates = [{ city: "Tokyo", lat: 35.68, lon: 139.69 }, { city: "Seoul", lat: 37.57, lon: 126.98 }]
    var clicked = null
    map.candidateClicked.connect(function(loc) { clicked = loc })
    var p = map.pointFor(35.68, 139.69)
    mouseMove(map, p.x + 2, p.y + 1)
    mouseMove(map, p.x + 3, p.y + 1)
    verify(map.hoverCandidate !== null, "hover set after mouse move")
    compare(map.hoverCandidate.city, "Tokyo")
    mouseMove(map, 3, 3)
    compare(map.hoverCandidate, null, "no city near the corner")
    mouseClick(map, p.x + 2, p.y + 1)
    verify(clicked !== null && clicked.city === "Tokyo", "click connects to the nearest city")
  }

  function test_markers_exit_square_home_circle() {
    var map = makeMap({ home: paris, exit: tokyo, linkState: "connected" })
    var ctx = fakeContext()
    map.paintMarkers(ctx)
    // Exit: halo rect + marker rect (+ label backing); home: one filled circle (+ label backing).
    verify(ctx.record.rects.length >= 2)
    compare(ctx.record.arcs.length, 1)
    compare(ctx.record.strokes, 0)
    fuzzyCompare(ctx.record.arcs[0].x, map.projectX(paris.lon), 1e-9)
    fuzzyCompare(ctx.record.arcs[0].y, map.projectY(paris.lat), 1e-9)
    var labels = ctx.record.texts.map(function(t) { return t.text })
    verify(labels.indexOf("Tokyo") >= 0)
    verify(labels.indexOf("Paris") >= 0)
  }

  function test_home_pulses_only_when_disconnected() {
    // The pulse is an item under the dynamic canvas, not a canvas stroke, so
    // that it can animate without repainting the link and the markers.
    var map = makeMap({ home: paris, exit: null, linkState: "none", pulseT: 0.5 })
    verify(map.pulseVisible)
    fuzzyCompare(map.pulseRadius, map.dotPitch * 2.2 * 0.5, 1e-6)
    fuzzyCompare(map.pulseOpacity, 0.5 * (1 - 0.5), 1e-6)
    map.pulseT = 0
    compare(map.pulseRadius, 0)
    fuzzyCompare(map.pulseOpacity, 0.5, 1e-6)
    map.pulseT = 1
    fuzzyCompare(map.pulseRadius, map.dotPitch * 2.2, 1e-6)
    fuzzyCompare(map.pulseOpacity, 0, 1e-6)

    // The canvas draws the home circle alone, in either state.
    var ctx = fakeContext()
    map.paintMarkers(ctx)
    compare(ctx.record.arcs.length, 1)
    compare(ctx.record.strokes, 0)
    fuzzyCompare(ctx.record.arcs[0].r, map.dotPitch * 0.6, 1e-6)
    var connected = fakeContext()
    map.exit = tokyo
    map.linkState = "connected"
    verify(!map.pulseVisible)
    map.paintMarkers(connected)
    compare(connected.record.arcs.length, 1)
    compare(connected.record.strokes, 0)
  }

  function test_the_pulse_needs_a_home_with_coordinates() {
    var map = makeMap({ home: null, exit: null, linkState: "none", pulseT: 0.5 })
    verify(!map.pulseVisible)
    map.home = { lat: null, lon: null, label: "Nowhere" }
    verify(!map.pulseVisible, "a home without coordinates never pulses at 0,0")
    map.home = paris
    verify(map.pulseVisible)
  }

  function test_the_phase_timer_only_runs_for_the_beads_and_the_draw_in() {
    // Nothing on the dynamic canvas follows `phase` unless the beads are
    // riding the link, so the timer that repaints it has to stop otherwise.
    var map = makeMap({ home: paris, exit: null, linkState: "none" })
    verify(!map.phaseActive, "disconnected: the pulse ring animates itself")
    map.linkState = "connecting"
    verify(map.phaseActive, "the link is drawing itself in")
    map.linkState = "connected"
    verify(!map.beadsVisible)
    verify(!map.phaseActive, "connected without an exit: no beads to move")
    map.exit = tokyo
    verify(map.beadsVisible)
    verify(map.phaseActive)
    map.home = null
    verify(!map.phaseActive)
  }

  function test_no_home_paints_no_markers() {
    var map = makeMap({ home: null, exit: null, linkState: "none" })
    var ctx = fakeContext()
    map.paintMarkers(ctx)
    compare(ctx.record.rects.length, 0)
    compare(ctx.record.arcs.length, 0)
  }

  function test_label_widths_are_measured_once_per_font() {
    var map = makeMap({ home: paris, exit: tokyo, linkState: "connected" })
    var first = fakeContext()
    map.paintMarkers(first)
    verify(first.record.measures.indexOf("Paris") >= 0)
    verify(first.record.measures.indexOf("Tokyo") >= 0)
    var second = fakeContext()
    map.paintMarkers(second)
    compare(second.record.measures.length, 0, "measured widths are reused")
    compare(second.record.texts.length, first.record.texts.length)
    map.labelPixelSize = map.labelPixelSize + 2
    var third = fakeContext()
    map.paintMarkers(third)
    verify(third.record.measures.length > 0, "a new font measures again")
  }

  function test_projected_candidates_are_cached_and_kept_fresh() {
    var map = makeMap({ home: paris, exit: null, linkState: "none" })
    map.candidates = [
      { city: "Tokyo", lat: 35.68, lon: 139.69 },
      { city: "NoCoords", lat: null, lon: null }
    ]
    compare(map.candidateX.length, 2)
    // Float32Array: pixel coordinates, so a thousandth of a pixel is exact
    // enough and the pointer walks a flat buffer.
    fuzzyCompare(map.candidateX[0], map.projectX(139.69), 1e-3)
    fuzzyCompare(map.candidateY[0], map.projectY(35.68), 1e-3)
    // Not 0,0: a location without coordinates must stay unpickable.
    verify(isNaN(map.candidateX[1]))
    verify(isNaN(map.candidateY[1]))
    // A resize reprojects, or every pick after it would be off.
    map.width = 240
    fuzzyCompare(map.candidateX[0], map.projectX(139.69), 1e-3)
    var p = map.pointFor(35.68, 139.69)
    compare(map.pickCandidate(p.x, p.y).city, "Tokyo")
  }
}
