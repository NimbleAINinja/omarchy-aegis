import QtQuick
import QtTest

// Panel.qml's popup content is built on first open rather than at shell
// start-up. The real thing needs Quickshell and the shell's own modules, which
// a headless qmltestrunner has not got, so this mirrors the wiring exactly —
// latched `popupReady`, a Loader inside the eager Flickable, a Component whose
// Column exposes `viewItem`, and the root properties that read back through
// the Loader — and checks the two things that wiring has to guarantee:
// nothing exists before the first open, and everything exists (and is
// measured) by the time that open returns. tests/model.test.js checks that
// Panel.qml still spells it this way.
TestCase {
  id: root
  name: "LazyPopup"
  visible: true
  width: 400
  height: 300
  when: windowShown

  property bool opened: false
  property bool popupReady: false
  property string view: "list"
  property int activated: -1
  property int contentBuilt: 0

  readonly property real popupContentHeight: contentLoader.item ? contentLoader.item.implicitHeight : 0
  readonly property var viewItem: contentLoader.item ? contentLoader.item.viewItem : null
  readonly property int listCount: viewItem ? viewItem.count : 0

  onOpenedChanged: if (opened) popupReady = true

  // The key catcher and the Flickable stay eager: the panel takes focus before
  // anything inside it exists.
  Item {
    id: keyCatcher
    anchors.fill: parent

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: root.popupContentHeight

      Loader {
        id: contentLoader
        width: panelFlick.width
        active: root.popupReady
        sourceComponent: popupContent
      }
    }
  }

  Component {
    id: popupContent
    Column {
      id: column
      spacing: 10
      readonly property var viewItem: viewLoader.item

      // Stands in for the WorldMap: the expensive thing that used to exist per
      // screen whether or not the panel was ever opened.
      Rectangle {
        width: parent.width
        height: 60
        Component.onCompleted: root.contentBuilt++
      }

      Loader {
        id: viewLoader
        width: parent.width
        sourceComponent: root.view === "account" ? accountView : listView
      }
    }
  }

  Component {
    id: listView
    Item {
      implicitHeight: 40
      readonly property int count: 7
      readonly property string kind: "list"
      function activate(index) { root.activated = index }
    }
  }

  Component {
    id: accountView
    Item {
      implicitHeight: 20
      readonly property int count: 0
      readonly property string kind: "account"
    }
  }

  function test_nothing_is_built_before_the_first_open() {
    compare(root.contentBuilt, 0, "no popup content at shell start-up")
    compare(contentLoader.item, null)
    // Everything Panel.qml reaches into the content with has to be null-safe:
    // the bar icon and the IPC verbs work with the popup never opened.
    compare(root.viewItem, null)
    compare(root.listCount, 0)
    compare(root.popupContentHeight, 0)
    // `view <name>` sets a property the view Loader reads whenever it is
    // built; it must not build anything itself.
    root.view = "account"
    compare(root.contentBuilt, 0)
    root.view = "list"
  }

  function test_opening_builds_it_once_and_measures_it_straight_away() {
    root.opened = true
    // Loaders are synchronous, so this all happened inside the property
    // change: the card measures the real column on the frame it fades in on,
    // with no one-frame size pop.
    verify(contentLoader.item !== null, "content built during onOpenedChanged")
    compare(root.contentBuilt, 1)
    verify(root.viewItem !== null)
    compare(root.viewItem.kind, "list")
    compare(root.listCount, 7)
    verify(root.popupContentHeight >= 110, "column measured: " + root.popupContentHeight)
    compare(panelFlick.contentHeight, root.popupContentHeight)
    // The Loader carries the width down to the column, which the rows inside
    // it take from their parent — the column no longer sets it itself.
    compare(contentLoader.width, panelFlick.width)
    compare(contentLoader.item.width, panelFlick.width)
    compare(contentLoader.item.children[0].width, panelFlick.width)

    // Loaded once, kept: a panel opened once is one the user opens again.
    root.opened = false
    verify(contentLoader.item !== null)
    root.opened = true
    compare(root.contentBuilt, 1, "reopening rebuilds nothing")

    // Switching views still works through the alias, both ways.
    root.view = "account"
    compare(root.viewItem.kind, "account")
    compare(root.listCount, 0)
    root.view = "list"
    compare(root.viewItem.kind, "list")
    compare(root.listCount, 7)
    root.viewItem.activate(3)
    compare(root.activated, 3)
  }
}
