import QtQuick
import QtTest
import "../../Model.js" as Model

// Headless checks for the ListModel LocationList.qml drives with
// Model.diffRows: that the in-place updates leave the view holding exactly the
// rows the array model used to hold (the keyboard cursor is an index into it),
// that a location object survives the round trip through the model with its
// nulls intact, and that untouched delegates are not rebuilt.
TestCase {
  id: suite
  name: "RowModel"
  visible: true
  width: 320
  height: 240
  when: windowShown

  // One role holding the whole location object, exactly as LocationList.qml
  // declares it.
  ListModel { id: rowModel; dynamicRoles: true }
  property var modelRows: []

  // Mirrors LocationList.qml's syncRows(); keep the two in step.
  function syncRows(next) {
    var ops = Model.diffRows(modelRows, next, Model.locationKey)
    for (var i = 0; i < ops.length; i++) {
      var op = ops[i]
      if (op.op === "reset") {
        rowModel.clear()
        for (var j = 0; j < op.rows.length; j++) rowModel.append({ entry: op.rows[j] })
      } else if (op.op === "remove") rowModel.remove(op.index, op.count)
      else if (op.op === "insert") rowModel.insert(op.index, { entry: op.row })
      else if (op.op === "set") rowModel.set(op.index, { entry: op.row })
    }
    modelRows = next
    return ops
  }

  property int built: 0
  property int destroyed: 0

  ListView {
    id: list
    width: 320
    height: 240
    model: rowModel
    // Same shape as LocationList.qml's delegate: the role is named `entry` so
    // it doesn't collide with the row component's own `loc` property.
    delegate: Row {
      required property var entry
      required property int index
      width: list.width
      loc: entry
      rowIndex: index
    }
  }

  component Row: Item {
    property var loc: null
    property int rowIndex: 0
    height: 20
    readonly property string city: loc ? String(loc.city) : ""
    Component.onCompleted: suite.built++
    Component.onDestruction: suite.destroyed++
  }

  function city(iso, name, ping) {
    return Model.normalizeLocations({ ok: true, locations: [{ iso: iso, country: "Country " + iso, city: name, pingMs: ping }] })[0]
  }

  function cities() {
    var out = []
    for (var i = 0; i < rowModel.count; i++) out.push(String(rowModel.get(i).entry.city))
    return out
  }

  function init() {
    rowModel.clear()
    modelRows = []
    suite.built = 0
    suite.destroyed = 0
  }

  function test_model_holds_exactly_the_rows_in_order() {
    var a = city("CA", "Montreal", 15), b = city("US", "New York", 23)
    var c = city("IL", "Tel Aviv", 140), d = city("ES", "Madrid", 60)
    syncRows([a, b, c, d])
    compare(rowModel.count, 4)
    compare(cities().join(","), "Montreal,New York,Tel Aviv,Madrid")
    // Typing filters the list down; indexes must close up with no gaps.
    syncRows([b, d])
    compare(rowModel.count, 2)
    compare(cities().join(","), "New York,Madrid")
    // Clearing the query brings them all back, in the same order as before.
    syncRows([a, b, c, d])
    compare(cities().join(","), "Montreal,New York,Tel Aviv,Madrid")
    // A reorder (favorites re-snapshotted on the next open).
    syncRows([d, c, b, a])
    compare(cities().join(","), "Madrid,Tel Aviv,New York,Montreal")
    syncRows([])
    compare(rowModel.count, 0)
  }

  function test_location_survives_the_round_trip_with_its_nulls() {
    var known = city("DE", "Berlin", 31)
    var unknown = Model.normalizeLocations({ ok: true, locations: [
      { iso: "in", country: "India", city: "Mumbai", cliName: "Mumbai (Virtual)", pingMs: null, virtual: true }
    ] })[0]
    syncRows([known, unknown])
    var one = rowModel.get(0).entry
    compare(one.iso, "DE")
    compare(one.city, "Berlin")
    compare(one.pingMs, 31)
    compare(one.virtual, false)
    compare(Model.pingTier(one.pingMs), "good")
    var two = rowModel.get(1).entry
    compare(two.cliName, "Mumbai (Virtual)")
    compare(two.virtual, true)
    // The nulls a plain ListModel would have coerced to 0.
    compare(two.pingMs, null)
    compare(two.lat, null)
    compare(two.lon, null)
    compare(Model.pingTier(two.pingMs), "none")
    compare(Model.locationKey(two), "IN|Mumbai")
  }

  function test_untouched_delegates_are_not_rebuilt() {
    var rows = []
    for (var i = 0; i < 6; i++) rows.push(city("C" + i, "City " + i, i * 10))
    syncRows(rows)
    wait(50)
    compare(rowModel.count, 6)
    var built = suite.built, destroyed = suite.destroyed
    verify(built >= 6, "delegates built for the first fill: " + built)

    // A snapshot that changed one ping rebuilds nothing.
    var repinged = rows.slice()
    repinged[2] = city("C2", "City 2", 999)
    syncRows(repinged)
    wait(50)
    compare(suite.built - built, 0, "no delegate rebuilt for a changed ping")
    compare(suite.destroyed - destroyed, 0)
    compare(String(rowModel.get(2).entry.pingMs), "999")

    // Typing takes rows away; the survivors keep their delegates.
    syncRows([repinged[0], repinged[2], repinged[5]])
    wait(50)
    compare(suite.built - built, 0, "no delegate rebuilt when rows are removed")
    compare(cities().join(","), "City 0,City 2,City 5")
    compare(list.count, 3)
  }
}
