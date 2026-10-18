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

  // Ping tints: the land dot nearest each of these is painted in its tier's
  // colour, so the map reads good/ok/poor exactly as the list does. Panel
  // builds the list (Model.dotTints) because this file may not import
  // Model.js; `tintDots` is the user's setting.
  property var dotTints: []            // [{lat, lon, tier}], tier: good | ok | poor
  property bool tintDots: true

  property color dotColor: Qt.rgba(1, 1, 1, 0.22)
  property color gridColor: Qt.rgba(1, 1, 1, 0.06)
  property color goodColor: "white"
  property color okColor: "white"
  property color poorColor: "white"
  property color markerColor: "white"
  property color accent: "white"
  property color textColor: "white"
  property color dimTextColor: "gray"    // the hovered city's ping, after its name
  property color haloColor: "black"
  property string fontFamily: "monospace"
  property real labelPixelSize: 10

  readonly property int beadCount: 4

  // The marching dash pattern used while connecting, in pixels along the arc.
  readonly property real dashLength: 6
  readonly property real dashGap: 4
  // Where the pattern starts. `phase` steps by 3 every 60 ms and wraps at 100,
  // a multiple of 20, so taking it modulo 20 walks one whole dash + gap every
  // 20 phase units — about 25 px/s toward the exit, the pace of the beads it
  // stands in for — and stays continuous across the wrap.
  readonly property real dashPhase: (phase % 20) / 20 * (dashLength + dashGap)

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
  // The lattice the cells sit on, kept so a point can be turned into a
  // column and a row without searching; see rebuildTints.
  property int cacheCols: 0
  property int cacheRows: 0
  property real cacheOffsetX: 0
  property real cacheOffsetY: 0
  // Bumped every time the cells are actually rebuilt, so the tint cache below
  // can tell "same cells" from "same size" without comparing buffers.
  property int cellsGeneration: 0

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
    cellsGeneration++
    if (!grid || width <= 0 || height <= 0 || dotPitch <= 0) {
      cellX = new Float32Array(0)
      cellY = new Float32Array(0)
      cacheCols = 0
      cacheRows = 0
      return
    }
    var pitch = dotPitch
    var cols = Math.floor(width / pitch)
    var rows = Math.floor(height / pitch)
    var offsetX = (width - cols * pitch) / 2
    var offsetY = (height - rows * pitch) / 2
    cacheCols = cols
    cacheRows = rows
    cacheOffsetX = offsetX
    cacheOffsetY = offsetY
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

  // The tinted dots, as flat buffers: where to paint and which tier's colour
  // to use (1 good, 2 ok, 3 poor — better tiers first, which is how two
  // locations landing on the same dot are resolved).
  property var tintX: new Float32Array(0)
  property var tintY: new Float32Array(0)
  property var tintTier: new Uint8Array(0)
  property int tintGeneration: -1
  property var tintSource: null

  function tierRank(tier) {
    if (tier === "good") return 1
    if (tier === "ok") return 2
    if (tier === "poor") return 3
    return 0
  }

  // Which land dot each tint belongs to, resolved once per cells/tints
  // change rather than per paint. The cells sit on a regular pitch lattice,
  // so the dot nearest a projected point is found by looking at the 3x3
  // neighbourhood of its own column and row; only a point with no land
  // anywhere near it (an island the 1° grid drops, a city out at sea) falls
  // back to a scan of every cell.
  // Land cell index by lattice slot, -1 where there is no land: what turns a
  // point into the dot nearest it without a scan. Built once per cells
  // generation, because both the tints and the hover highlight need it and the
  // highlight is asked for on every pointer move.
  property var cellSlots: new Int32Array(0)
  property int slotGeneration: -1

  function rebuildSlots() {
    if (slotGeneration === cellsGeneration) return
    slotGeneration = cellsGeneration
    var cols = cacheCols
    var rows = cacheRows
    var cells = cellX.length
    if (cols <= 0 || rows <= 0 || cells === 0 || dotPitch <= 0) {
      cellSlots = new Int32Array(0)
      return
    }
    var slots = new Int32Array(cols * rows)
    for (var s = 0; s < slots.length; s++) slots[s] = -1
    var pitch = dotPitch
    for (var i = 0; i < cells; i++) {
      var col = Math.floor((cellX[i] - cacheOffsetX) / pitch)
      var row = Math.floor((cellY[i] - cacheOffsetY) / pitch)
      if (col >= 0 && col < cols && row >= 0 && row < rows) slots[row * cols + col] = i
    }
    cellSlots = slots
  }

  function rebuildTints() {
    if (tintGeneration === cellsGeneration && tintSource === dotTints) return
    tintGeneration = cellsGeneration
    tintSource = dotTints
    var tints = dotTints || []
    var cells = cellX.length
    if (!tintDots || tints.length === 0 || cells === 0) {
      if (tintTier.length > 0) {
        tintX = new Float32Array(0)
        tintY = new Float32Array(0)
        tintTier = new Uint8Array(0)
      }
      if (cellTier.length > 0) cellTier = new Uint8Array(0)
      return
    }
    rebuildSlots()
    var i
    // One tier per land cell, the best one that asked for it.
    var best = new Uint8Array(cells)
    for (var t = 0; t < tints.length; t++) {
      var tint = tints[t]
      var rank = tierRank(tint ? String(tint.tier) : "")
      // Number(null) and Number("") are both a finite 0, so a tint without
      // coordinates would otherwise land on the dot nearest 0,0 — the same
      // trap Link.finiteCoord exists for.
      if (rank === 0 || !Link.finiteCoord(tint)) continue
      var hit = nearestCell(projectX(Number(tint.lon)), projectY(Number(tint.lat)))
      if (hit < 0) continue
      if (best[hit] === 0 || rank < best[hit]) best[hit] = rank
    }
    var xs = new Float32Array(cells)
    var ys = new Float32Array(cells)
    var tiers = new Uint8Array(cells)
    var found = 0
    for (i = 0; i < cells; i++) {
      if (best[i] === 0) continue
      xs[found] = cellX[i]
      ys[found] = cellY[i]
      tiers[found] = best[i]
      found++
    }
    tintX = xs.slice(0, found)
    tintY = ys.slice(0, found)
    tintTier = tiers.slice(0, found)
    cellTier = best
  }

  // Tier per land cell (0 = untinted), indexed like cellX: what paintMarkers
  // asks to know whether the dot under a hover ring is already a coloured one.
  property var cellTier: new Uint8Array(0)

  function cellTinted(index) {
    return tintDots && index >= 0 && index < cellTier.length && cellTier[index] !== 0
  }

  function nearestCell(x, y) {
    if (!isFinite(x) || !isFinite(y)) return -1
    var slots = cellSlots
    if (slots.length === 0) return -1
    var cols = cacheCols
    var rows = cacheRows
    var pitch = dotPitch
    var col = Math.floor((x - cacheOffsetX) / pitch)
    var row = Math.floor((y - cacheOffsetY) / pitch)
    var best = -1
    var bestDist = Infinity
    for (var r = row - 1; r <= row + 1; r++) {
      if (r < 0 || r >= rows) continue
      for (var c = col - 1; c <= col + 1; c++) {
        if (c < 0 || c >= cols) continue
        var index = slots[r * cols + c]
        if (index < 0) continue
        var dx = cellX[index] - x
        var dy = cellY[index] - y
        var dist = dx * dx + dy * dy
        if (dist < bestDist) { bestDist = dist; best = index }
      }
    }
    if (best >= 0) return best
    for (var i = 0; i < cellX.length; i++) {
      var ex = cellX[i] - x
      var ey = cellY[i] - y
      var far = ex * ex + ey * ey
      if (far < bestDist) { bestDist = far; best = i }
    }
    return best
  }

  // Where a city's highlight belongs: on the land dot that stands for it. The
  // ping tint is painted on the nearest cell (rebuildTints), so a ring drawn at
  // the raw projection sat up to half a cell off the very dot it was ringing —
  // most visible on a coastal city, where the nearest land dot is inland.
  // Snapping both through the same slot table keeps them concentric whether or
  // not tinting is on; with no cells — no grid loaded yet — the projection is
  // all there is to point at.
  function snapToCell(x, y) {
    if (cellX.length === 0) return { x: x, y: y, index: -1 }
    rebuildSlots()
    var hit = nearestCell(x, y)
    return hit < 0 ? { x: x, y: y, index: -1 } : { x: cellX[hit], y: cellY[hit], index: hit }
  }

  // Over the land dots, on the same static layer, in the tier's colour and a
  // touch larger than a land dot: at a 4 px pitch the dots are 2 px squares,
  // and at that size a tint reads as a slightly off-colour speck rather than a
  // city. One pass per tier, so the context takes three fill styles at most.
  function paintTints(ctx) {
    if (!tintDots) return
    var count = tintTier.length
    if (count === 0) return
    var side = Math.max(2, Math.round(dotPitch * Math.min(1, dotFill + 0.25)))
    var half = side / 2
    var colors = [goodColor, okColor, poorColor]
    for (var rank = 1; rank <= 3; rank++) {
      var painted = false
      for (var i = 0; i < count; i++) {
        if (tintTier[i] !== rank) continue
        if (!painted) { ctx.fillStyle = colors[rank - 1]; painted = true }
        ctx.fillRect(Math.round(tintX[i] - half), Math.round(tintY[i] - half), side, side)
      }
    }
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

  // One traced path holding every dash as its own subpath: a stroke covers
  // them all, so the halo and the core still cost one trace and two strokes.
  // Butt caps, or the halo's 4px round ends would close the 4px gaps and the
  // dashes would read as a solid line again.
  function traceDashes(ctx, seg, tEnd) {
    var parts = Link.dashes(seg, tEnd < 0 ? 1 : tEnd, dashLength, dashGap, dashPhase)
    ctx.beginPath()
    for (var i = 0; i < parts.length; i++) {
      var points = parts[i]
      ctx.moveTo(points[0].x, points[0].y)
      for (var k = 1; k < points.length; k++) ctx.lineTo(points[k].x, points[k].y)
    }
  }

  // A fat translucent halo under a thin bright core. The path survives a
  // stroke, so both share one trace; tEnd < 0 means the whole segment.
  function strokeLink(ctx, seg, tEnd, dashed) {
    ctx.lineCap = dashed ? "butt" : "round"
    ctx.lineJoin = "round"
    if (dashed) traceDashes(ctx, seg, tEnd)
    else if (tEnd < 0) traceSegment(ctx, seg)
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
    // Dashes marching toward the exit while the tunnel is coming up; a solid
    // arc the moment it is up. The beads below say the same thing, and they
    // may only ride a link that carries traffic.
    var dashed = linkState === "connecting"
    var progress = Math.max(0, Math.min(1, drawProgress))
    if (progress >= 1) {
      for (var i = 0; i < segs.length; i++) strokeLink(ctx, segs[i], -1, dashed)
    } else {
      // Progress runs across the whole link by chord length, so segment B
      // only starts once A is fully drawn.
      var parts = Link.progressSegments(segs, progress)
      for (var j = 0; j < parts.length; j++) {
        var part = parts[j]
        if (part.tEnd <= 0) continue
        strokeLink(ctx, part, part.tEnd, dashed)
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

  // What follows the hovered city's name: its ping, in the quieter colour,
  // so the map answers what the list's ping column does without a trip to
  // the list. Nothing for a city that has no ping yet.
  function pingSuffix(loc) {
    if (!loc || loc.pingMs === null || loc.pingMs === undefined) return ""
    var ms = Number(loc.pingMs)
    return isFinite(ms) && ms >= 0 ? " | " + Math.round(ms) + "ms" : ""
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
    // A ring around the city, drawn over the land dots so it reads even where
    // the link passes; a hovered candidate also gets a label. Ring, dot and
    // label all sit on the snapped dot (snapToCell) — the exit and home
    // markers keep their exact projections, because they mark a place rather
    // than pick one of the dots out. When that dot already carries a ping tint
    // the ring alone is the highlight, so the tier colour stays visible inside
    // it; a bright centre dot is only painted where there is no tint to show
    // (tinting off, or a city whose dot has no ping).
    // Number(null)/Number("") coerce to a finite 0, so this reuses
    // Link.finiteCoord rather than isFinite(Number(...)) directly — the
    // same trap that once put coordinate-less locations at 0,0 in
    // Link.nearest (see Link.js).
    var focus = Link.finiteCoord(hoverCandidate) ? hoverCandidate : hover
    if (Link.finiteCoord(focus)) {
      var spot = snapToCell(projectX(Number(focus.lon)), projectY(Number(focus.lat)))
      var vx = spot.x
      var vy = spot.y
      if (focus === hoverCandidate) {
        var ring = dotPitch * 1.6
        placed.push({ x: vx - ring, y: vy - ring, w: ring * 2, h: ring * 2 })
        labels.unshift({ text: shortLabel(String(focus.city || focus.label || "")), suffix: pingSuffix(focus), x: vx, y: vy, reach: ring + gap })
      }
      ctx.beginPath()
      ctx.arc(vx, vy, dotPitch * 1.6, 0, Math.PI * 2)
      ctx.strokeStyle = cssLinkCore
      ctx.lineWidth = 1.2
      ctx.stroke()
      rebuildTints()
      if (!cellTinted(spot.index)) {
        ctx.beginPath()
        ctx.arc(vx, vy, Math.max(1.5, dotPitch * 0.45), 0, Math.PI * 2)
        ctx.fillStyle = cssAccent
        ctx.fill()
      }
    }

    var textHeight = Math.round(labelPixelSize) + 2
    for (var j = 0; j < labels.length; j++) {
      var label = labels[j].text
      if (label === "") continue
      var px = labels[j].x
      var py = labels[j].y
      var reach = labels[j].reach
      var suffix = labels[j].suffix || ""
      var labelW = labelWidth(ctx, label)
      var textWidth = labelW + (suffix !== "" ? labelWidth(ctx, suffix) : 0)
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
        // Drawn from the box's left edge, which the placement above already
        // put where the alignment wanted it, so a two-tone label lines up.
        ctx.textAlign = "left"
        ctx.textBaseline = candidates[c].baseline
        ctx.fillStyle = textColor
        ctx.fillText(label, box.x, candidates[c].ty)
        if (suffix !== "") {
          ctx.fillStyle = dimTextColor
          ctx.fillText(suffix, box.x + labelW, candidates[c].ty)
        }
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
  // The tints live on the static layer, so they repaint with it — and a new
  // list (or the setting going off and on) has to invalidate the cache the
  // cells generation alone would call current.
  onDotTintsChanged: baseCanvas.requestPaint()
  onTintDotsChanged: { tintGeneration = -1; baseCanvas.requestPaint() }
  onGoodColorChanged: baseCanvas.requestPaint()
  onOkColorChanged: baseCanvas.requestPaint()
  onPoorColorChanged: baseCanvas.requestPaint()
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
  // While connecting the phase moves the dashes, not the beads, so the
  // dynamic layer has to follow it there too.
  onPhaseChanged: if (beadsVisible || linkState === "connecting") dotCanvas.requestPaint()
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
      root.rebuildTints()
      root.paintGrid(ctx)
      root.paintDots(ctx)
      root.paintTints(ctx)
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
