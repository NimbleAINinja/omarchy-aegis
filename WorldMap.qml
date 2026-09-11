import QtQuick
import "Grid.js" as Grid
import "Link.js" as Link

// Dot-matrix world map with a single animated link from home to the VPN exit.
//
// Land is a grid of small squares sampled from a precomputed 1° land mask.
// The only colours are the ones injected by the caller, so the map stays
// monochrome on every theme; the link, beads and home marker use `accent`.
//
// Imports nothing but QtQuick and two pure JS files so it can be exercised
// headlessly; every paint routine takes the 2D context as a parameter for the
// same reason.
Item {
  id: root

  property var grid: null              // decoded by Grid.decodeRle
  property var home: null              // {lat, lon, label} or null
  property var exit: null              // {lat, lon, label} or null
  property var hover: null             // {lat, lon} of the row under the cursor, or null
  property var candidates: []          // clickable locations [{city, lat, lon, ...}]
  property var hoverCandidate: null    // nearest candidate to the pointer, or null
  readonly property real pickRadius: Math.max(10, dotPitch * 4)
  signal candidateClicked(var location)

  // Pixel positions of `candidates`, rebuilt when they or the geometry
  // change: a pointer event otherwise re-projected all ~80 cities, twice
  // each, through two QML functions. Float32Array, so the pointer walks a
  // flat buffer; a location without coordinates is stored as NaN, which
  // Link.nearestProjected skips.
  property var candidateX: new Float32Array(0)
  property var candidateY: new Float32Array(0)

  function rebuildProjected() {
    var list = candidates || []
    var count = list.length
    var xs = new Float32Array(count)
    var ys = new Float32Array(count)
    for (var i = 0; i < count; i++) {
      var p = list[i]
      var ok = Link.finiteCoord(p)
      xs[i] = ok ? projectX(Number(p.lon)) : NaN
      ys[i] = ok ? projectY(Number(p.lat)) : NaN
    }
    candidateX = xs
    candidateY = ys
  }

  function pickCandidate(x, y) {
    var hit = Link.nearestProjected(candidateX, candidateY, candidates, x, y, pickRadius)
    return hit ? hit.point : null
  }
  property string linkState: "none"    // "none" | "connecting" | "connected"
  property int phase: 0                // 0..99, advanced by the animation timer
  property real drawProgress: 0        // 0..1, how much of the link is drawn in
  property bool animate: true
  property bool showGrid: true
  property real dotPitch: 4
  property real dotFill: 0.55
  // Latitude range shown; the default crops the empty Southern Ocean and the
  // polar cap, which is where the classic dot maps stop.
  property real latMin: -58
  property real latMax: 84

  property color dotColor: Qt.rgba(1, 1, 1, 0.22)
  property color gridColor: Qt.rgba(1, 1, 1, 0.06)
  property color markerColor: "white"
  property color accent: "white"
  property color textColor: "white"
  property color haloColor: "black"
  property string fontFamily: "monospace"
  property real labelPixelSize: 10

  readonly property int beadCount: 4

  implicitHeight: Math.round(width * (latMax - latMin) / 360)

  // Land cells for the current size, rebuilt only when geometry changes.
  property var cellX: new Float32Array(0)
  property var cellY: new Float32Array(0)
  // What cellX/cellY were built for. Compared field by field: rebuildCells
  // runs on every paint of the static layer, and a cache key string would be
  // built (and thrown away) each time.
  property real cacheW: -1
  property real cacheH: -1
  property real cachePitch: -1
  property real cacheLatMin: 0
  property real cacheLatMax: 0
  property var cacheGrid: null

  // Link geometry in map pixels, one or two quadratic segments (two when the
  // shorter way round crosses the antimeridian).
  readonly property var segments: computeSegments(home, exit, linkState, width, height, latMin, latMax)

  // The dynamic layer only has to follow `phase` while the beads ride the
  // link or the link is drawing itself in; the disconnected pulse ring
  // animates itself (see homePulse).
  readonly property bool beadsVisible: linkState === "connected" && segments.length > 0
  readonly property bool phaseActive: home !== null && (beadsVisible || linkState === "connecting")

  // Home pulse, while there is no link. Ramps out to dotPitch * 2.2 and fades.
  readonly property bool pulseVisible: home !== null && linkState === "none" && Link.finiteCoord(home)
  property real pulseT: 0
  readonly property real pulseRadius: dotPitch * 2.2 * pulseT
  readonly property real pulseOpacity: 0.5 * (1 - pulseT)

  function projectX(lon) { return (lon + 180) / 360 * width }
  function projectY(lat) { return (latMax - lat) / (latMax - latMin) * height }
  function lonAt(x) { return x / width * 360 - 180 }
  function latAt(y) { return latMax - y / height * (latMax - latMin) }
  function pointFor(lat, lon) { return { x: projectX(lon), y: projectY(lat) } }

  function withAlpha(color, alpha) {
    return Qt.rgba(color.r, color.g, color.b, alpha)
  }

  // Canvas 2D wants CSS colour strings for strokes and fills.
  function css(color, alpha) {
    return "rgba(" + Math.round(color.r * 255) + "," + Math.round(color.g * 255) + "," + Math.round(color.b * 255) + "," + alpha + ")"
  }

  // The accent at the four alphas the link and the markers use it at, as
  // the strings the context wants: css() ran on every paint otherwise. The
  // colours that are used at their own alpha (dotColor, markerColor,
  // haloColor, textColor) go to the context as colours, which is both exact
  // and free — building a string for them would round each channel to 1/255.
  readonly property string cssLinkHalo: css(accent, 0.22)
  readonly property string cssLinkCore: css(accent, 0.9)
  readonly property string cssAccent: css(accent, 1)
  readonly property string cssBead: css(Qt.lighter(accent, 1.4), 1)

  function canvasFont() {
    var family = String(fontFamily || "monospace")
    if (family.indexOf(" ") >= 0 && family.charAt(0) !== "'") family = "'" + family + "'"
    return Math.max(6, Math.round(labelPixelSize)) + "px " + family
  }

  // Label metrics are the same from paint to paint for the same string in the
  // same font, and measureText is the most expensive call in paintMarkers.
  readonly property string labelFont: canvasFont()
  property var labelWidths: ({})
  onLabelFontChanged: labelWidths = ({})

  function labelWidth(ctx, text) {
    var cached = labelWidths[text]
    if (cached !== undefined) return cached
    var measured = ctx.measureText(text).width
    labelWidths[text] = measured
    return measured
  }

  function computeSegments(homePoint, exitPoint, state, w, h, lo, hi) {
    if (!homePoint || !exitPoint || state === "none" || w <= 0 || h <= 0) return []
    return Link.segments(homePoint, exitPoint, projectX, projectY, w)
  }

  function rebuildCells() {
    if (width === cacheW && height === cacheH && dotPitch === cachePitch
        && latMin === cacheLatMin && latMax === cacheLatMax && grid === cacheGrid) return
    cacheW = width
    cacheH = height
    cachePitch = dotPitch
    cacheLatMin = latMin
    cacheLatMax = latMax
    cacheGrid = grid
    if (!grid || width <= 0 || height <= 0 || dotPitch <= 0) {
      cellX = new Float32Array(0)
      cellY = new Float32Array(0)
      return
    }
    var pitch = dotPitch
    var cols = Math.floor(width / pitch)
    var rows = Math.floor(height / pitch)
    var offsetX = (width - cols * pitch) / 2
    var offsetY = (height - rows * pitch) / 2
    // Pixel coordinates, so float32 is more precision than the canvas can
    // use; filled into a buffer for every cell and trimmed to the land ones.
    var xs = new Float32Array(rows * cols)
    var ys = new Float32Array(rows * cols)
    var found = 0
    for (var r = 0; r < rows; r++) {
      var cy = offsetY + (r + 0.5) * pitch
      var lat = latAt(cy)
      for (var c = 0; c < cols; c++) {
        var cx = offsetX + (c + 0.5) * pitch
        if (!Grid.isLand(grid, lonAt(cx), lat)) continue
        xs[found] = cx
        ys[found] = cy
        found++
      }
    }
    cellX = xs.slice(0, found)
    cellY = ys.slice(0, found)
  }

  function paintGrid(ctx) {
    if (!showGrid || width <= 0 || height <= 0) return
    ctx.lineWidth = 1
    for (var lon = -150; lon <= 150; lon += 30) {
      var x = Math.round(projectX(lon)) + 0.5
      ctx.strokeStyle = lon === 0 ? withAlpha(gridColor, Math.min(1, gridColor.a * 1.6)) : gridColor
      ctx.beginPath()
      ctx.moveTo(x, 0)
      ctx.lineTo(x, height)
      ctx.stroke()
    }
    for (var lat = -60; lat <= 60; lat += 30) {
      if (lat < latMin || lat > latMax) continue
      var y = Math.round(projectY(lat)) + 0.5
      ctx.strokeStyle = lat === 0 ? withAlpha(gridColor, Math.min(1, gridColor.a * 1.6)) : gridColor
      ctx.beginPath()
      ctx.moveTo(0, y)
      ctx.lineTo(width, y)
      ctx.stroke()
    }
  }

  function paintDots(ctx) {
    var count = cellX.length
    if (count === 0) return
    var side = Math.max(1, Math.round(dotPitch * dotFill))
    var half = side / 2
    var xs = cellX, ys = cellY
    ctx.fillStyle = dotColor
    for (var i = 0; i < count; i++)
      ctx.fillRect(Math.round(xs[i] - half), Math.round(ys[i] - half), side, side)
  }

  function traceSegment(ctx, seg) {
    ctx.beginPath()
    ctx.moveTo(seg.x0, seg.y0)
    ctx.quadraticCurveTo(seg.cx, seg.cy, seg.x1, seg.y1)
  }

  function tracePartial(ctx, seg, tEnd) {
    var points = Link.polyline(seg, tEnd, 24)
    ctx.beginPath()
    for (var i = 0; i < points.length; i++) {
      if (i === 0) ctx.moveTo(points[i].x, points[i].y)
      else ctx.lineTo(points[i].x, points[i].y)
    }
  }

  // A fat translucent halo under a thin bright core. The path survives a
  // stroke, so both share one trace; tEnd < 0 means the whole segment.
  function strokeLink(ctx, seg, tEnd) {
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    if (tEnd < 0) traceSegment(ctx, seg)
    else tracePartial(ctx, seg, tEnd)
    ctx.strokeStyle = cssLinkHalo
    ctx.lineWidth = 4
    ctx.stroke()
    ctx.strokeStyle = cssLinkCore
    ctx.lineWidth = 1.4
    ctx.stroke()
  }

  function paintLink(ctx) {
    var segs = segments
    if (segs.length === 0) return
    var progress = Math.max(0, Math.min(1, drawProgress))
    if (progress >= 1) {
      for (var i = 0; i < segs.length; i++) strokeLink(ctx, segs[i], -1)
    } else {
      // Progress runs across the whole link by chord length, so segment B
      // only starts once A is fully drawn.
      var parts = Link.progressSegments(segs, progress)
      for (var j = 0; j < parts.length; j++) {
        var part = parts[j]
        if (part.tEnd <= 0) continue
        strokeLink(ctx, part, part.tEnd)
      }
    }
    if (linkState !== "connected") return
    var beads = Link.beadPositions(segs, phase, beadCount)
    ctx.fillStyle = cssBead
    for (var b = 0; b < beads.length; b++) {
      ctx.beginPath()
      ctx.arc(beads[b].x, beads[b].y, 2.1, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  function shortLabel(label) {
    var text = String(label || "")
    return text.length > 14 ? text.substring(0, 13) + "…" : text
  }

  function rectsOverlap(a, b) {
    return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
  }

  function paintMarkers(ctx) {
    var placed = []
    var labels = []
    var size = Math.max(3, Math.round(dotPitch * 0.9))
    var gap = Math.max(3, Math.round(dotPitch * 0.75))
    ctx.font = labelFont
    ctx.lineJoin = "round"

    if (exit && linkState !== "none") {
      var ex = projectX(exit.lon)
      var ey = projectY(exit.lat)
      var half = size / 2
      placed.push({ x: ex - half, y: ey - half, w: size, h: size })
      ctx.fillStyle = haloColor
      ctx.fillRect(Math.round(ex - half) - 1, Math.round(ey - half) - 1, size + 2, size + 2)
      ctx.fillStyle = markerColor
      ctx.fillRect(Math.round(ex - half), Math.round(ey - half), size, size)
      labels.push({ text: shortLabel(exit.label), x: ex, y: ey, reach: half + gap })
    }

    if (home) {
      var hx = projectX(home.lon)
      var hy = projectY(home.lat)
      var radius = dotPitch * 0.6
      // The pulse ring around it is the homePulse item, below this canvas.
      ctx.beginPath()
      ctx.arc(hx, hy, radius, 0, Math.PI * 2)
      ctx.fillStyle = cssAccent
      ctx.fill()
      placed.push({ x: hx - radius, y: hy - radius, w: radius * 2, h: radius * 2 })
      labels.push({ text: shortLabel(home.label), x: hx, y: hy, reach: radius + gap })
    }

    // Highlight: the candidate under the pointer wins over the list cursor.
    // A ring around the city plus a bright dot, drawn over the land dots so it
    // reads even where the link passes; a hovered candidate also gets a label.
    // Number(null)/Number("") coerce to a finite 0, so this reuses
    // Link.finiteCoord rather than isFinite(Number(...)) directly — the
    // same trap that once put coordinate-less locations at 0,0 in
    // Link.nearest (see Link.js).
    var focus = Link.finiteCoord(hoverCandidate) ? hoverCandidate : hover
    if (Link.finiteCoord(focus)) {
      var vx = projectX(Number(focus.lon))
      var vy = projectY(Number(focus.lat))
      if (focus === hoverCandidate) {
        var ring = dotPitch * 1.6
        placed.push({ x: vx - ring, y: vy - ring, w: ring * 2, h: ring * 2 })
        labels.unshift({ text: shortLabel(String(focus.city || focus.label || "")), x: vx, y: vy, reach: ring + gap })
      }
      ctx.beginPath()
      ctx.arc(vx, vy, dotPitch * 1.6, 0, Math.PI * 2)
      ctx.strokeStyle = cssLinkCore
      ctx.lineWidth = 1.2
      ctx.stroke()
      ctx.beginPath()
      ctx.arc(vx, vy, Math.max(1.5, dotPitch * 0.45), 0, Math.PI * 2)
      ctx.fillStyle = cssAccent
      ctx.fill()
    }

    var textHeight = Math.round(labelPixelSize) + 2
    for (var j = 0; j < labels.length; j++) {
      var label = labels[j].text
      if (label === "") continue
      var px = labels[j].x
      var py = labels[j].y
      var reach = labels[j].reach
      var textWidth = labelWidth(ctx, label)
      var candidates = [
        { x: px + reach, y: py - textHeight / 2, align: "left", baseline: "middle", tx: px + reach, ty: py },
        { x: px - reach - textWidth, y: py - textHeight / 2, align: "right", baseline: "middle", tx: px - reach, ty: py },
        { x: px - textWidth / 2, y: py - reach - textHeight, align: "center", baseline: "bottom", tx: px, ty: py - reach },
        { x: px - textWidth / 2, y: py + reach, align: "center", baseline: "top", tx: px, ty: py + reach }
      ]
      for (var c = 0; c < candidates.length; c++) {
        var box = { x: candidates[c].x, y: candidates[c].y, w: textWidth, h: textHeight }
        if (box.x < 0 || box.y < 0 || box.x + box.w > width || box.y + box.h > height) continue
        var collides = false
        for (var p = 0; p < placed.length; p++) {
          if (rectsOverlap(box, placed[p])) { collides = true; break }
        }
        if (collides) continue
        // Solid backing so the label stays readable over the dots and the link.
        var padX = 3
        var padY = 1
        var backing = { x: box.x - padX, y: box.y - padY, w: box.w + padX * 2, h: box.h + padY * 2 }
        placed.push(backing)
        ctx.fillStyle = haloColor
        ctx.fillRect(Math.round(backing.x), Math.round(backing.y), Math.round(backing.w), Math.round(backing.h))
        ctx.textAlign = candidates[c].align
        ctx.textBaseline = candidates[c].baseline
        ctx.fillStyle = textColor
        ctx.fillText(label, candidates[c].tx, candidates[c].ty)
        break
      }
    }
  }

  function repaintAll() {
    rebuildCells()
    rebuildProjected()
    baseCanvas.requestPaint()
    dotCanvas.requestPaint()
  }

  // A resize brings a new canvas context, so the measurements taken from the
  // old one are dropped with it.
  onWidthChanged: { labelWidths = ({}); repaintAll() }
  onHeightChanged: repaintAll()
  onDotPitchChanged: repaintAll()
  onGridChanged: repaintAll()
  onLatMinChanged: repaintAll()
  onLatMaxChanged: repaintAll()
  onShowGridChanged: baseCanvas.requestPaint()
  onGridColorChanged: baseCanvas.requestPaint()
  onDotFillChanged: baseCanvas.requestPaint()
  onDotColorChanged: baseCanvas.requestPaint()
  onHomeChanged: dotCanvas.requestPaint()
  onExitChanged: dotCanvas.requestPaint()
  onHoverChanged: dotCanvas.requestPaint()
  onHoverCandidateChanged: dotCanvas.requestPaint()
  onCandidatesChanged: { rebuildProjected(); dotCanvas.requestPaint() }
  onLinkStateChanged: {
    if (linkState === "connected") drawProgress = 1
    else drawProgress = 0
    dotCanvas.requestPaint()
  }
  onPhaseChanged: if (beadsVisible) dotCanvas.requestPaint()
  onDrawProgressChanged: dotCanvas.requestPaint()
  onMarkerColorChanged: dotCanvas.requestPaint()
  onAccentChanged: dotCanvas.requestPaint()
  onTextColorChanged: dotCanvas.requestPaint()
  onHaloColorChanged: dotCanvas.requestPaint()
  onFontFamilyChanged: dotCanvas.requestPaint()
  onLabelPixelSizeChanged: dotCanvas.requestPaint()
  Component.onCompleted: repaintAll()

  // Every tick repaints the dynamic layer, so the tick costs a canvas paint
  // and not just the step it takes. At 60 ms with proportionally larger steps
  // the beads travel and the link draws in at exactly the same speed as they
  // did at 40 ms, for two paints a second less than half the paints.
  Timer {
    interval: 60
    repeat: true
    running: root.animate && root.visible && root.phaseActive
    onTriggered: {
      root.phase = (root.phase + 3) % 100
      if (root.linkState === "connecting") root.drawProgress = Math.min(1, root.drawProgress + 0.06)
    }
  }

  // One cycle of the pulse ring, 2 s, exactly as 50 phase ticks used to be.
  NumberAnimation {
    target: root
    property: "pulseT"
    from: 0
    to: 1
    duration: 2000
    loops: Animation.Infinite
    running: root.pulseVisible && root.animate && root.visible
  }

  // Static layer: graticule and the ~1800 land dots. Neither depends on the
  // link, the pointer or the animation phase, so this repaints only when the
  // geometry, the grid or one of the two dot colours changes.
  Canvas {
    id: baseCanvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onAvailableChanged: if (available) requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      if (!ctx) return
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      root.rebuildCells()
      root.paintGrid(ctx)
      root.paintDots(ctx)
    }
  }

  // The home pulse, as an item so that it can animate without repainting a
  // canvas. It belongs between the two layers, which is where the canvas
  // stroke that drew it used to sit: it only ever shows while there is no
  // link, and the markers above it still cover it. A ring of radius r stroked
  // 1px wide covers [r - 0.5, r + 0.5], which is a 2r + 1 wide rounded
  // rectangle with a 1px inner border.
  Rectangle {
    id: homePulse
    visible: root.pulseVisible && root.pulseRadius > 0
    width: root.pulseRadius * 2 + 1
    height: width
    radius: width / 2
    x: (root.pulseVisible ? root.projectX(Number(root.home.lon)) : 0) - width / 2
    y: (root.pulseVisible ? root.projectY(Number(root.home.lat)) : 0) - height / 2
    color: "transparent"
    border.width: 1
    border.color: root.withAlpha(root.accent, root.pulseOpacity)
    antialiasing: true
  }

  // Dynamic layer: the link with its beads, and the markers with their labels.
  Canvas {
    id: dotCanvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onAvailableChanged: if (available) requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      if (!ctx) return
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      root.paintLink(ctx)
      root.paintMarkers(ctx)
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.hoverCandidate ? Qt.PointingHandCursor : Qt.ArrowCursor
    onPositionChanged: function(mouse) { root.hoverCandidate = root.pickCandidate(mouse.x, mouse.y) }
    onExited: root.hoverCandidate = null
    onClicked: function(mouse) {
      var hit = root.pickCandidate(mouse.x, mouse.y)
      if (hit) root.candidateClicked(hit)
    }
  }
}
