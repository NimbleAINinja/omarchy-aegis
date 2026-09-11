// Land/water grid decode and lookup.
//
// `assets/land-grid.json` stores a rows × cols raster as per-row run lengths
// alternating water/land, always starting with water (a first run of 0 means
// the row starts with land). Cell (row r, col c) is centred on
//   lat = 90 - (r + 0.5) * 180 / rows,  lon = -180 + (c + 0.5) * 360 / cols.
//
// Pure ES5, no QML dependencies: shared by WorldMap.qml, the build tool and
// the node tests.

function decodeRle(json) {
  if (!json || typeof json !== "object") throw new Error("land grid: not an object")
  var cols = json.cols | 0
  var rows = json.rows | 0
  if (cols <= 0 || rows <= 0) throw new Error("land grid: bad dimensions")
  if (!Array.isArray(json.rle) || json.rle.length !== rows) throw new Error("land grid: row count mismatch")
  var bits = new Uint8Array(cols * rows)
  for (var r = 0; r < rows; r++) {
    var runs = json.rle[r]
    if (!Array.isArray(runs)) throw new Error("land grid: row " + r + " is not an array")
    var c = 0
    var land = 0
    for (var k = 0; k < runs.length; k++) {
      var n = runs[k] | 0
      if (n < 0 || c + n > cols) throw new Error("land grid: row " + r + " overflows")
      if (land) {
        var base = r * cols
        for (var i = c; i < c + n; i++) bits[base + i] = 1
      }
      c += n
      land = 1 - land
    }
    if (c !== cols) throw new Error("land grid: row " + r + " sums to " + c + ", expected " + cols)
  }
  return { cols: cols, rows: rows, bits: bits }
}

function columnFor(grid, lon) {
  var u = ((lon + 180) % 360 + 360) % 360
  var col = Math.floor(u / 360 * grid.cols)
  return col >= grid.cols ? 0 : col
}

function rowFor(grid, lat) {
  var row = Math.floor((90 - lat) / 180 * grid.rows)
  if (row < 0) return 0
  if (row >= grid.rows) return grid.rows - 1
  return row
}

function isLand(grid, lon, lat) {
  if (!grid || !grid.bits) return false
  return grid.bits[rowFor(grid, lat) * grid.cols + columnFor(grid, lon)] === 1
}

function landFraction(grid) {
  if (!grid || !grid.bits || grid.bits.length === 0) return 0
  var count = 0
  for (var i = 0; i < grid.bits.length; i++) if (grid.bits[i]) count++
  return count / grid.bits.length
}

if (typeof module !== "undefined") {
  module.exports = {
    decodeRle: decodeRle,
    columnFor: columnFor,
    rowFor: rowFor,
    isLand: isLand,
    landFraction: landFraction
  }
}
