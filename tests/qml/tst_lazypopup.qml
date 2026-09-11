import QtQuick
import QtTest

// Panel.qml's popup content is built on first open rather than at shell
// start-up, and its icon-bar footer sits outside the scrolling area. The real
// thing needs Quickshell and the shell's own modules, which a headless
// qmltestrunner has not got, so this mirrors the wiring exactly — latched
// `popupReady`, two Loaders on that latch (the column inside the eager
// Flickable, the footer block anchored to the bottom of the key catcher), the
// Flickable ending where the footer begins, and the root properties that read
// back through both Loaders — and checks the three things that wiring has to
// guarantee: nothing exists before the first open, everything exists (and is
// measured) by the time that open returns, and the footer never scrolls away.
// tests/model.test.js checks that Panel.qml still spells it this way.
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
  property int footerBuilt: 0
  // Stands in for a view that outgrows the card (a long location list, the
  // settings tab); the last test turns it up.
  property real listHeight: 40

  // The Flickable scrolls the column alone; the card sizes to the column, one
  // gap, and the footer that no longer scrolls with it.
  readonly property real popupColumnHeight: contentLoader.item ? contentLoader.item.implicitHeight : 0
  readonly property real popupFooterHeight: footerLoader.item ? footerLoader.item.implicitHeight : 0
  readonly property real popupContentHeight: popupColumnHeight > 0
    ? popupColumnHeight + 10 + popupFooterHeight : 0
  readonly property var viewItem: contentLoader.item ? contentLoader.item.viewItem : null
  readonly property int listCount: viewItem ? viewItem.count : 0

  onOpenedChanged: if (opened) popupReady = true

  // The key catcher, the Flickable and both Loaders stay eager: the panel takes
  // focus before anything inside it exists.
  Item {
    id: keyCatcher
    anchors.fill: parent

    Flickable {
      id: panelFlick
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: footerLoader.top
      contentWidth: width
      contentHeight: root.popupColumnHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Loader {
        id: contentLoader
        width: panelFlick.width
        active: root.popupReady
        sourceComponent: popupContent
      }
    }

    Loader {
      id: footerLoader
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      active: root.popupReady
      sourceComponent: popupFooter
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
    id: popupFooter
    Column {
      id: footerBlock
      spacing: 10
      Component.onCompleted: root.footerBuilt++

      // The separator, then the icon bar.
      Rectangle { width: parent.width; height: 1 }

      Row {
        width: parent.width
        height: 24
        Rectangle { width: 24; height: 24 }
      }
    }
  }

  Component {
    id: listView
    Item {
      implicitHeight: root.listHeight
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
    compare(root.footerBuilt, 0, "no footer at shell start-up")
    compare(contentLoader.item, null)
    compare(footerLoader.item, null)
    // Everything Panel.qml reaches into the content with has to be null-safe:
    // the bar icon and the IPC verbs work with the popup never opened.
    compare(root.viewItem, null)
    compare(root.listCount, 0)
    compare(root.popupColumnHeight, 0)
    compare(root.popupFooterHeight, 0)
    compare(root.popupContentHeight, 0)
    // An inactive footer Loader is zero-high, so the Flickable fills the card.
    compare(footerLoader.height, 0)
    compare(panelFlick.height, keyCatcher.height)
    // `view <name>` sets a property the view Loader reads whenever it is
    // built; it must not build anything itself.
    root.view = "account"
    compare(root.contentBuilt, 0)
    root.view = "list"
  }

  function test_opening_builds_it_once_and_measures_it_straight_away() {
    root.opened = true
    // Loaders are synchronous, so this all happened inside the property
    // change: the card measures the real column and the real footer on the
    // frame it fades in on, with no one-frame size pop.
    verify(contentLoader.item !== null, "content built during onOpenedChanged")
    verify(footerLoader.item !== null, "footer built during onOpenedChanged")
    compare(root.contentBuilt, 1)
    compare(root.footerBuilt, 1)
    verify(root.viewItem !== null)
    compare(root.viewItem.kind, "list")
    compare(root.listCount, 7)
    verify(root.popupColumnHeight >= 110, "column measured: " + root.popupColumnHeight)
    verify(root.popupFooterHeight >= 35, "footer measured: " + root.popupFooterHeight)
    // The card takes column + gap + footer; the Flickable scrolls the column
    // alone, so the footer can never be scrolled out from under it.
    compare(root.popupContentHeight, root.popupColumnHeight + 10 + root.popupFooterHeight)
    compare(panelFlick.contentHeight, root.popupColumnHeight)
    // The Loader carries the width down to the column, which the rows inside
    // it take from their parent — the column no longer sets it itself.
    compare(contentLoader.width, panelFlick.width)
    compare(contentLoader.item.width, panelFlick.width)
    compare(contentLoader.item.children[0].width, panelFlick.width)

    // Loaded once, kept: a panel opened once is one the user opens again.
    root.opened = false
    verify(contentLoader.item !== null)
    verify(footerLoader.item !== null)
    root.opened = true
    compare(root.contentBuilt, 1, "reopening rebuilds nothing")
    compare(root.footerBuilt, 1, "reopening rebuilds nothing")

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

  function test_the_footer_stays_put_while_a_tall_view_scrolls() {
    root.opened = true
    // The footer is a sibling of the Flickable, not something inside its
    // content: that is what keeps it out of the scroll.
    compare(footerLoader.parent, keyCatcher)
    compare(contentLoader.parent, panelFlick.contentItem)
    var restingY = footerLoader.mapToItem(keyCatcher, 0, 0).y
    compare(restingY + footerLoader.height, keyCatcher.height)
    compare(panelFlick.height, keyCatcher.height - footerLoader.height)

    // A view taller than the card: the column now overflows the Flickable.
    // A Column re-measures itself on the next polish, not on the assignment.
    root.listHeight = 800
    tryVerify(function() { return panelFlick.contentHeight > panelFlick.height }, 2000,
      "the column must outgrow the viewport")
    compare(panelFlick.contentHeight, root.popupColumnHeight)
    var columnTop = contentLoader.mapToItem(keyCatcher, 0, 0).y

    panelFlick.contentY = panelFlick.contentHeight - panelFlick.height
    verify(panelFlick.contentY > 0, "the flickable scrolled")
    // The column moved by exactly what was scrolled; the footer did not move
    // at all and is still sitting on the bottom edge.
    compare(contentLoader.mapToItem(keyCatcher, 0, 0).y, columnTop - panelFlick.contentY)
    compare(footerLoader.mapToItem(keyCatcher, 0, 0).y, restingY)
    compare(restingY + footerLoader.height, keyCatcher.height)
    // And the bottom of the column is above the footer, not under it.
    verify(columnTop - panelFlick.contentY + panelFlick.contentHeight <= restingY + 0.5)

    root.listHeight = 40
  }
}
