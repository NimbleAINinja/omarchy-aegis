const test = require("node:test")
const assert = require("node:assert/strict")
const Link = require("../Link.js")

const W = 520, H = 205
const px = lon => (lon + 180) / 360 * W
const py = lat => (84 - lat) / (84 + 58) * H

const PARIS = { lat: 48.86, lon: 2.35 }
const TOKYO = { lat: 35.68, lon: 139.69 }
const LA = { lat: 34.05, lon: -118.24 }
const MONTREAL = { lat: 45.5, lon: -73.57 }
const TEL_AVIV = { lat: 32.08, lon: 34.78 }

function chordLength(seg) {
  return Math.hypot(seg.x1 - seg.x0, seg.y1 - seg.y0)
}

test("controlPoint sits on the perpendicular bisector and bows upward", () => {
  const c = Link.controlPoint(0, 100, 200, 100)
  assert.equal(Math.round(c.x), 100)
  assert.ok(c.y < 100, "bows toward smaller y")
  assert.equal(Math.round(100 - c.y), Math.round(0.22 * 200))
  const r = Link.controlPoint(200, 100, 0, 100)
  assert.ok(r.y < 100, "still bows upward when drawn right to left")
  const custom = Link.controlPoint(0, 0, 100, 0, 0.5)
  assert.equal(Math.round(-custom.y), 50)
  const degenerate = Link.controlPoint(5, 5, 5, 5)
  assert.ok(isFinite(degenerate.x) && isFinite(degenerate.y))
})

test("pointOnQuad hits the endpoints and the midpoint formula", () => {
  const p0 = Link.pointOnQuad(0, 0, 50, -40, 100, 0, 0)
  const p1 = Link.pointOnQuad(0, 0, 50, -40, 100, 0, 1)
  const mid = Link.pointOnQuad(0, 0, 50, -40, 100, 0, 0.5)
  assert.deepEqual(p0, { x: 0, y: 0 })
  assert.deepEqual(p1, { x: 100, y: 0 })
  assert.equal(mid.x, 50)
  assert.equal(mid.y, -20)
})

test("segments: Paris to Tokyo is a single arc", () => {
  const segs = Link.segments(PARIS, TOKYO, px, py, W)
  assert.equal(segs.length, 1)
  assert.equal(segs[0].x0, px(PARIS.lon))
  assert.equal(segs[0].y0, py(PARIS.lat))
  assert.equal(segs[0].x1, px(TOKYO.lon))
  assert.equal(segs[0].y1, py(TOKYO.lat))
  assert.ok(segs[0].cy < Math.max(segs[0].y0, segs[0].y1))
})

test("segments: Montreal to Tel Aviv is a single arc", () => {
  const segs = Link.segments(MONTREAL, TEL_AVIV, px, py, W)
  assert.equal(segs.length, 1)
})

test("segments: Tokyo home to Los Angeles stays inside the map, never splitting at the edge", () => {
  const segs = Link.segments(TOKYO, LA, px, py, W)
  assert.equal(segs.length, 1)
  assert.equal(segs[0].x0, px(TOKYO.lon))
  assert.equal(segs[0].x1, px(LA.lon), "ends on the real Los Angeles x, crossing the map interior")
  assert.ok(segs[0].cx > 0 && segs[0].cx < W, "control point inside the map")
  assert.ok(segs[0].cy <= Math.max(segs[0].y0, segs[0].y1), "bows upward")
})

test("segments: Los Angeles home to Tokyo is the mirror, also a single interior arc", () => {
  const segs = Link.segments(LA, TOKYO, px, py, W)
  assert.equal(segs.length, 1)
  assert.equal(segs[0].x0, px(LA.lon))
  assert.equal(segs[0].x1, px(TOKYO.lon))
})

test("segments returns nothing without both endpoints", () => {
  assert.deepEqual(Link.segments(null, TOKYO, px, py, W), [])
  assert.deepEqual(Link.segments(PARIS, { lat: null, lon: null }, px, py, W), [])
})

const SPLIT = [
  { x0: px(TOKYO.lon), y0: py(TOKYO.lat), cx: 500, cy: 40, x1: W, y1: 70 },
  { x0: 0, y0: 70, cx: 40, cy: 40, x1: px(LA.lon), y1: py(LA.lat) }
]

test("beadPositions spaces beads evenly by chord length across a split", () => {
  const segs = SPLIT
  const total = chordLength(segs[0]) + chordLength(segs[1])
  const beads = Link.beadPositions(segs, 0, 4)
  assert.equal(beads.length, 4)
  beads.forEach(b => {
    assert.ok(b.x >= 0 && b.x <= W, "bead inside map width: " + b.x)
    assert.ok(isFinite(b.y))
  })
  // Successive beads on the same segment are separated by total/4 along the
  // chord, within a pixel (the curve bows so measure by parameter distance).
  const t = Link.beadParams(segs, 0, 4)
  assert.equal(t.length, 4)
  for (let i = 1; i < t.length; i++) {
    assert.ok(Math.abs((t[i] - t[i - 1]) * total - total / 4) < 1, "spacing " + i)
  }
  const shifted = Link.beadParams(segs, 50, 4)
  assert.ok(Math.abs(((shifted[0] - t[0] + 1) % 1) - 0.125) < 1e-9, "phase 50 shifts by half a gap")
  assert.deepEqual(Link.beadPositions([], 10, 4), [])
})

test("beadPositions on a single segment lands on the curve", () => {
  const segs = Link.segments(PARIS, TOKYO, px, py, W)
  const beads = Link.beadPositions(segs, 25, 2)
  assert.equal(beads.length, 2)
  const t = Link.beadParams(segs, 25, 2)
  const expect = Link.pointOnQuad(segs[0].x0, segs[0].y0, segs[0].cx, segs[0].cy, segs[0].x1, segs[0].y1, t[0])
  assert.ok(Math.abs(beads[0].x - expect.x) < 1e-9 && Math.abs(beads[0].y - expect.y) < 1e-9)
})

test("polyline samples the arc up to tEnd", () => {
  const seg = { x0: 0, y0: 0, cx: 50, cy: -40, x1: 100, y1: 0 }
  const full = Link.polyline(seg, 1, 10)
  assert.equal(full.length, 11)
  assert.deepEqual(full[0], { x: 0, y: 0 })
  assert.deepEqual(full[10], { x: 100, y: 0 })
  const half = Link.polyline(seg, 0.5, 10)
  assert.equal(half.length, 11)
  const mid = Link.pointOnQuad(0, 0, 50, -40, 100, 0, 0.5)
  assert.ok(Math.abs(half[10].x - mid.x) < 1e-9 && Math.abs(half[10].y - mid.y) < 1e-9)
  assert.deepEqual(Link.polyline(seg, 0, 10), [{ x: 0, y: 0 }])
})

test("progressSegments clips a two-segment link by overall progress", () => {
  const segs = SPLIT
  const lenA = chordLength(segs[0])
  const total = lenA + chordLength(segs[1])
  const early = Link.progressSegments(segs, (lenA / total) * 0.5)
  assert.equal(early.length, 1)
  assert.ok(early[0].tEnd > 0.49 && early[0].tEnd < 0.51)
  const late = Link.progressSegments(segs, (lenA / total) + (1 - lenA / total) * 0.25)
  assert.equal(late.length, 2)
  assert.equal(late[0].tEnd, 1)
  assert.ok(late[1].tEnd > 0.24 && late[1].tEnd < 0.26)
  const done = Link.progressSegments(segs, 1)
  assert.deepEqual(done.map(s => s.tEnd), [1, 1])
})

test("nearest picks the closest projected point within maxDist, else null", () => {
  const pts = [
    { city: "Paris", lat: 48.86, lon: 2.35 },
    { city: "Brussels", lat: 50.85, lon: 4.35 },
    { city: "Tokyo", lat: 35.68, lon: 139.69 },
    { city: "NoCoords", lat: null, lon: null }
  ]
  const paris = { x: px(2.35), y: py(48.86) }
  const hit = Link.nearest(pts, paris.x - 2, paris.y + 1, px, py, 12)
  assert.equal(hit.point.city, "Paris")
  assert.ok(hit.dist < 3)
  const brussels = { x: px(4.35), y: py(50.85) }
  assert.equal(Link.nearest(pts, brussels.x, brussels.y, px, py, 12).point.city, "Brussels")
  assert.equal(Link.nearest(pts, 5, 5, px, py, 12), null, "nothing within reach")
  assert.equal(Link.nearest([], paris.x, paris.y, px, py, 12), null)
  assert.equal(Link.nearest(pts, paris.x, paris.y, px, py, 0), null, "maxDist 0 never matches")
})

test("nearest never returns a location missing coordinates, even right at 0,0", () => {
  // The bug: Number(null) and Number("") are both 0 (a finite number), so a
  // location without coordinates used to be placed at 0,0 on the map and
  // could be hovered/clicked there.
  const pts = [
    { city: "NullCoords", lat: null, lon: null },
    { city: "UndefinedCoords", lat: undefined, lon: undefined },
    { city: "EmptyStringCoords", lat: "", lon: "" },
    { city: "MixedCoords", lat: 10, lon: "" },
    { city: "Paris", lat: 48.86, lon: 2.35 }
  ]
  const nullIsland = { x: px(0), y: py(0) }
  // Right on top of where a coordinate-less point would land at 0,0: still
  // nothing found, and definitely not one of the coordinate-less points.
  assert.equal(Link.nearest(pts, nullIsland.x, nullIsland.y, px, py, 12), null)
  // The real point is still found normally elsewhere on the map.
  const paris = { x: px(2.35), y: py(48.86) }
  assert.equal(Link.nearest(pts, paris.x, paris.y, px, py, 12).point.city, "Paris")
})

// Projections of `items` as WorldMap caches them: NaN where the location has
// no usable coordinates, which is what keeps it off 0,0.
function project(items) {
  const xs = [], ys = []
  for (const p of items) {
    const ok = Link.finiteCoord(p)
    xs.push(ok ? px(Number(p.lon)) : NaN)
    ys.push(ok ? py(Number(p.lat)) : NaN)
  }
  return [xs, ys]
}

test("nearestProjected picks the same point as nearest, without projecting", () => {
  const pts = [
    { city: "Paris", lat: 48.86, lon: 2.35 },
    { city: "Brussels", lat: 50.85, lon: 4.35 },
    { city: "NoCoords", lat: null, lon: null }
  ]
  const [xs, ys] = project(pts)
  const paris = { x: px(2.35), y: py(48.86) }
  const hit = Link.nearestProjected(xs, ys, pts, paris.x - 2, paris.y + 1, 12)
  assert.equal(hit.point.city, "Paris")
  assert.ok(hit.dist < 3)
  assert.equal(hit.x, paris.x)
  assert.equal(hit.y, paris.y)
  assert.equal(Link.nearestProjected(xs, ys, pts, 5, 5, 12), null, "nothing within reach")
  assert.equal(Link.nearestProjected(xs, ys, pts, paris.x, paris.y, 0), null, "maxDist 0 never matches")
  assert.equal(Link.nearestProjected([], [], [], paris.x, paris.y, 12), null)
  assert.equal(Link.nearestProjected(null, null, pts, paris.x, paris.y, 12), null, "no cache yet")
  // A cache that lags behind the list only offers what it covers.
  const brussels = { x: px(4.35), y: py(50.85) }
  assert.equal(Link.nearestProjected(xs, ys, pts, brussels.x, brussels.y, 3).point.city, "Brussels")
  assert.equal(Link.nearestProjected(xs.slice(0, 1), ys.slice(0, 1), pts, brussels.x, brussels.y, 3), null)
})

test("nearestProjected never returns a location missing coordinates, even right at 0,0", () => {
  const pts = [
    { city: "NullCoords", lat: null, lon: null },
    { city: "EmptyStringCoords", lat: "", lon: "" },
    { city: "MixedCoords", lat: 10, lon: "" },
    { city: "Paris", lat: 48.86, lon: 2.35 }
  ]
  const [xs, ys] = project(pts)
  assert.equal(Link.nearestProjected(xs, ys, pts, px(0), py(0), 12), null)
  assert.equal(Link.nearestProjected(xs, ys, pts, px(2.35), py(48.86), 12).point.city, "Paris")
})

test("nearestProjected agrees with nearest on random inputs", () => {
  // Deterministic PRNG so a disagreement is reproducible.
  let seed = 0x2f6e2b1
  const rnd = () => {
    seed = (seed + 0x6d2b79f5) | 0
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
  const broken = [null, undefined, "", NaN, "nope", Infinity]
  let found = 0
  for (let round = 0; round < 400; round++) {
    const pts = []
    for (let i = 0; i < 1 + Math.floor(rnd() * 30); i++) {
      if (rnd() < 0.25) {
        // A location with one or both coordinates unusable.
        const lat = rnd() < 0.5 ? broken[Math.floor(rnd() * broken.length)] : rnd() * 180 - 90
        const lon = rnd() < 0.5 ? broken[Math.floor(rnd() * broken.length)] : rnd() * 360 - 180
        pts.push({ city: "broken" + i, lat, lon })
      } else {
        pts.push({ city: "city" + i, lat: rnd() * 140 - 56, lon: rnd() * 360 - 180 })
      }
    }
    const [xs, ys] = project(pts)
    const x = rnd() * W
    const y = rnd() * H
    const radius = 5 + rnd() * 120
    const slow = Link.nearest(pts, x, y, px, py, radius)
    const fast = Link.nearestProjected(xs, ys, pts, x, y, radius)
    if (slow === null) {
      assert.equal(fast, null, `round ${round}: nearest found nothing`)
      continue
    }
    found++
    assert.equal(fast.point, slow.point, `round ${round}: same location`)
    assert.ok(Math.abs(fast.dist - slow.dist) < 1e-9, `round ${round}: same distance`)
    assert.equal(fast.x, slow.x)
    assert.equal(fast.y, slow.y)
  }
  assert.ok(found > 100, `expected plenty of hits, got ${found}`)
})
