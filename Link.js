// Arc geometry for the home → exit link on the flat (equirectangular) map.
// Pure ES5, no QML dependencies: shared by WorldMap.qml and the node tests.
//
// A link is one quadratic bezier, or two when the short way round crosses the
// antimeridian: the curve is cut at the map edge and continued from the
// opposite edge, so both pieces stay inside [0, width].

function controlPoint(x0, y0, x1, y1, bulge) {
  var mx = (x0 + x1) / 2
  var my = (y0 + y1) / 2
  var dx = x1 - x0
  var dy = y1 - y0
  var len = Math.sqrt(dx * dx + dy * dy) || 1
  var nx = -dy / len
  var ny = dx / len
  var amp = (bulge === undefined ? 0.22 : bulge) * len
  // Always bow "up" on the map (smaller y).
  if (ny > 0) {
    nx = -nx
    ny = -ny
  }
  return { x: mx + nx * amp, y: my + ny * amp }
}

function pointOnQuad(x0, y0, cx, cy, x1, y1, t) {
  var u = 1 - t
  return {
    x: u * u * x0 + 2 * u * t * cx + t * t * x1,
    y: u * u * y0 + 2 * u * t * cy + t * t * y1
  }
}

function finiteCoord(p) {
  if (!p) return false
  var lat = p.lat, lon = p.lon
  // Number(null) and Number("") are both 0 — a finite number — so a
  // location missing coordinates entirely (null from the JSON, or an empty
  // string from somewhere loose) must be rejected explicitly, not left to
  // isFinite() to catch.
  if (lat === null || lat === undefined || lat === "" || lon === null || lon === undefined || lon === "") return false
  return isFinite(Number(lat)) && isFinite(Number(lon))
}

function makeSegment(x0, y0, x1, y1) {
  var c = controlPoint(x0, y0, x1, y1)
  return { x0: x0, y0: y0, cx: c.x, cy: c.y, x1: x1, y1: y1 }
}

function segments(home, exit, projectX, projectY, width) {
  if (!finiteCoord(home) || !finiteCoord(exit)) return []
  // Always draw straight across the map interior. The geodesic short way
  // would leave through one edge and re-enter at the other, which reads as
  // two unrelated strokes on a flat map; one continuous arc is clearer.
  var x0 = projectX(Number(home.lon))
  var y0 = projectY(Number(home.lat))
  var x1 = projectX(Number(exit.lon))
  var y1 = projectY(Number(exit.lat))
  return [makeSegment(x0, y0, x1, y1)]
}

function chordLength(seg) {
  var dx = seg.x1 - seg.x0
  var dy = seg.y1 - seg.y0
  return Math.sqrt(dx * dx + dy * dy)
}

function totalLength(segs) {
  var total = 0
  for (var i = 0; i < segs.length; i++) total += chordLength(segs[i])
  return total
}

// Global bead parameters in [0, 1) over the whole link, evenly spaced and
// shifted by phase (0..99) so that phase 100 equals one full gap.
function beadParams(segs, phase, count) {
  if (!segs || segs.length === 0 || !(count > 0)) return []
  var shift = ((Number(phase) || 0) % 100) / 100
  var out = []
  for (var i = 0; i < count; i++) out.push(((i + shift) / count) % 1)
  return out
}

// Map a global parameter (by chord length) onto a segment and its local t.
function locate(segs, t) {
  var total = totalLength(segs)
  var target = t * total
  var start = 0
  for (var i = 0; i < segs.length; i++) {
    var len = chordLength(segs[i])
    if (target <= start + len || i === segs.length - 1) {
      var local = len > 0 ? (target - start) / len : 0
      if (local < 0) local = 0
      if (local > 1) local = 1
      return { seg: segs[i], t: local }
    }
    start += len
  }
  return { seg: segs[0], t: 0 }
}

function beadPositions(segs, phase, count) {
  var params = beadParams(segs, phase, count)
  var out = []
  for (var i = 0; i < params.length; i++) {
    var hit = locate(segs, params[i])
    var s = hit.seg
    out.push(pointOnQuad(s.x0, s.y0, s.cx, s.cy, s.x1, s.y1, hit.t))
  }
  return out
}

function polyline(seg, tEnd, steps) {
  var end = Number(tEnd)
  if (!(end > 0)) return [{ x: seg.x0, y: seg.y0 }]
  if (end > 1) end = 1
  var n = Math.max(1, Math.round(Number(steps) || 24))
  var out = []
  for (var k = 0; k <= n; k++) {
    var t = end * k / n
    out.push(pointOnQuad(seg.x0, seg.y0, seg.cx, seg.cy, seg.x1, seg.y1, t))
  }
  return out
}

// The point `s` pixels along a sampled curve, interpolated inside the sample
// it falls in. `at[i]` is the arc length of pts[i] from the start.
function pointAtLength(pts, at, s) {
  var last = at.length - 1
  if (!(s > 0)) return { x: pts[0].x, y: pts[0].y }
  if (s >= at[last]) return { x: pts[last].x, y: pts[last].y }
  var i = 1
  while (i < last && at[i] < s) i++
  var span = at[i] - at[i - 1]
  var f = span > 0 ? (s - at[i - 1]) / span : 0
  return { x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
    y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * f }
}

// One dash, from arc length `a` to `b`: the two cut points with every sample
// between them kept, so a dash bends with the arc instead of chording it.
function dashCut(pts, at, a, b) {
  var out = [pointAtLength(pts, at, a)]
  for (var i = 0; i < pts.length; i++) {
    if (at[i] > a && at[i] < b) out.push({ x: pts[i].x, y: pts[i].y })
  }
  out.push(pointAtLength(pts, at, b))
  return out
}

// The link cut into marching dashes, for the connecting state. Qt's Canvas 2D
// context has no setLineDash (the symbol isn't in libQt6Quick at all), so the
// pattern is cut here and handed back as polylines the caller strokes.
//   seg: one quadratic segment; tEnd: how much of it to cover (0..1)
//   dashLen/gapLen: the pattern in pixels, measured along the curve
//   phaseOffset: how far along the curve the pattern starts, so raising it
//     over time walks the dashes toward the exit
// → [[{x, y}, ...], ...], every point on the curve. The dash the offset pushed
// off the start is kept, clipped: without it the first pixels of the link
// would blink in and out as the pattern marched past them.
function dashes(seg, tEnd, dashLen, gapLen, phaseOffset) {
  var end = Number(tEnd)
  if (!(end > 0)) return []
  if (end > 1) end = 1
  var dash = Number(dashLen)
  if (!(dash > 0)) return []
  var gap = Number(gapLen)
  if (!(gap > 0)) gap = 0
  var period = dash + gap
  var pts = polyline(seg, end, 64)
  var at = [0]
  var total = 0
  for (var i = 1; i < pts.length; i++) {
    var dx = pts[i].x - pts[i - 1].x
    var dy = pts[i].y - pts[i - 1].y
    total += Math.sqrt(dx * dx + dy * dy)
    at.push(total)
  }
  if (!(total > 0)) return []
  var off = Number(phaseOffset)
  if (!isFinite(off)) off = 0
  off = off % period
  if (off < 0) off += period
  var out = []
  for (var start = off - period; start < total; start += period) {
    var a = start
    var b = start + dash
    if (b <= 0) continue
    if (a < 0) a = 0
    if (b > total) b = total
    if (b <= a) continue
    out.push(dashCut(pts, at, a, b))
  }
  return out
}

// Split an overall progress (0..1 by chord length) into per-segment tEnd
// values; segments not yet reached are omitted.
function progressSegments(segs, progress) {
  if (!segs || segs.length === 0) return []
  var p = Number(progress)
  if (!(p > 0)) p = 0
  if (p > 1) p = 1
  var total = totalLength(segs)
  var target = p * total
  var start = 0
  var out = []
  for (var i = 0; i < segs.length; i++) {
    var len = chordLength(segs[i])
    var tEnd = len > 0 ? (target - start) / len : (target >= start ? 1 : 0)
    if (tEnd > 1) tEnd = 1
    if (tEnd <= 0 && i > 0) break
    if (tEnd < 0) tEnd = 0
    var copy = { x0: segs[i].x0, y0: segs[i].y0, cx: segs[i].cx, cy: segs[i].cy, x1: segs[i].x1, y1: segs[i].y1, tEnd: tEnd }
    out.push(copy)
    start += len
  }
  return out
}

// Closest projected point to (x, y) within maxDist pixels, or null. Points
// without finite coordinates are skipped. Used for map hover and click.
function nearest(points, x, y, projectX, projectY, maxDist) {
  var list = points || []
  var best = null
  var bestDist = Number(maxDist)
  if (!(bestDist > 0)) return null
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    // Number(null)/Number("") coerce to 0 — a finite number — so without
    // finiteCoord a location missing coordinates would be placed at 0,0
    // and could be hovered/clicked there. See also finiteCoord's own doc.
    if (!finiteCoord(p)) continue
    var lat = Number(p.lat), lon = Number(p.lon)
    var dx = projectX(lon) - x
    var dy = projectY(lat) - y
    var d = Math.sqrt(dx * dx + dy * dy)
    if (d <= bestDist && (best === null || d < best.dist)) {
      best = { point: p, dist: d, x: projectX(lon), y: projectY(lat) }
      bestDist = d
    }
  }
  return best
}

// The same pick over points that are already projected: xs[i] and ys[i] are
// the pixel position of items[i]. Comparing squared distances saves the
// square root, and a point whose coordinates were not finite is stored as
// NaN, which fails every comparison below — that is the finiteCoord skip
// nearest() does inline, kept so that a location without coordinates is
// never picked at 0,0. Used for map hover and click, where nearest() would
// otherwise re-project every city on every pointer event.
function nearestProjected(xs, ys, items, x, y, maxDist) {
  var list = items || []
  var limit = Number(maxDist)
  if (!(limit > 0)) return null
  if (!xs || !ys) return null
  var count = Math.min(list.length, xs.length, ys.length)
  var best = null
  var bestDist2 = limit * limit
  for (var i = 0; i < count; i++) {
    var dx = xs[i] - x
    var dy = ys[i] - y
    var dist2 = dx * dx + dy * dy
    if (dist2 <= bestDist2 && (best === null || dist2 < bestDist2)) {
      best = { point: list[i], dist: Math.sqrt(dist2), x: xs[i], y: ys[i] }
      bestDist2 = dist2
    }
  }
  return best
}

if (typeof module !== "undefined") {
  module.exports = {
    controlPoint: controlPoint,
    pointOnQuad: pointOnQuad,
    finiteCoord: finiteCoord,
    segments: segments,
    chordLength: chordLength,
    totalLength: totalLength,
    beadParams: beadParams,
    beadPositions: beadPositions,
    polyline: polyline,
    pointAtLength: pointAtLength,
    dashes: dashes,
    progressSegments: progressSegments,
    nearest: nearest,
    nearestProjected: nearestProjected
  }
}
