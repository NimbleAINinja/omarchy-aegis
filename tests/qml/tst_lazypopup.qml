import QtQuick
import QtTest

// Panel.qml's popup content is built on first open rather than at shell
// start-up, and only the middle of the card scrolls. The real thing needs
// Quickshell and the shell's own modules, which a headless qmltestrunner has
// not got, so this mirrors the wiring exactly — latched `popupReady`, three
// Loaders on that latch (the header block anchored to the top of the key
// catcher, the view column inside the eager Flickable, the footer block
// anchored to the bottom), the Flickable running from the header's bottom to
// the footer's top, and the root properties that read back through all three —
// and checks the three things that wiring has to guarantee: nothing exists
// before the first open, everything exists (and is measured) by the time that
// open returns, and neither the header nor the footer ever scrolls away.
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
  property int headerBuilt: 0
  property int contentBuilt: 0
  property int footerBuilt: 0
  // Stands in for a view that outgrows the card (a long location list, the
  // settings tab); the last test turns it up.
  property real listHeight: 40

  // The Flickable scrolls the view alone; the card sizes to the header, the
  // view, the footer and a gap on either side of the view.
  readonly property real popupColumnHeight: contentLoader.item ? contentLoader.item.implicitHeight : 0
  readonly property real popupHeaderHeight: headerLoader.item ? headerLoader.item.implicitHeight : 0
  readonly property real popupFooterHeight: footerLoader.item ? footerLoader.item.implicitHeight : 0
  readonly property real popupContentHeight: popupColumnHeight > 0
    ? popupHeaderHeight + 10 + popupColumnHeight + 10 + popupFooterHeight : 0
  readonly property var viewItem: contentLoader.item ? contentLoader.item.viewItem : null
  readonly property int listCount: viewItem ? viewItem.count : 0

  onOpenedChanged: if (opened) popupReady = true

  // The key catcher, the Flickable and all three Loaders stay eager: the panel
  // takes focus before anything inside it exists.
  Item {
    id: keyCatcher
    anchors.fill: parent

    Loader {
      id: headerLoader
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      active: root.popupReady
      sourceComponent: popupHeader
    }

    Flickable {
      id: panelFlick
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: headerLoader.bottom
      anchors.topMargin: 10
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
    id: popupHeader
    Column {
      id: headerBlock
      spacing: 10
      Component.onCompleted: root.headerBuilt++

      // Stands in for the WorldMap: the expensive thing that used to exist per
      // screen whether or not the panel was ever opened.
      Rectangle {
        width: parent.width
        height: 60
      }

      // The hero, then the rule under it.
      Rectangle { width: parent.width; height: 28 }
      Rectangle { width: parent.width; height: 1 }
    }
  }

  Component {
    id: popupContent
    Column {
      id: column
      spacing: 10
      readonly property var viewItem: viewLoader.item
      Component.onCompleted: root.contentBuilt++

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
    compare(root.headerBuilt, 0, "no map or hero at shell start-up")
    compare(root.contentBuilt, 0, "no popup content at shell start-up")
    compare(root.footerBuilt, 0, "no footer at shell start-up")
    compare(headerLoader.item, null)
    compare(contentLoader.item, null)
    compare(footerLoader.item, null)
    // Everything Panel.qml reaches into the content with has to be null-safe:
    // the bar icon and the IPC verbs work with the popup never opened.
    compare(root.viewItem, null)
    compare(root.listCount, 0)
    compare(root.popupColumnHeight, 0)
    compare(root.popupHeaderHeight, 0)
    compare(root.popupFooterHeight, 0)
    compare(root.popupContentHeight, 0)
    // Two inactive Loaders are zero-high, so the Flickable all but fills the
    // card — with nothing in it.
    compare(headerLoader.height, 0)
    compare(footerLoader.height, 0)
    compare(panelFlick.height, keyCatcher.height - 10)
    // `view <name>` sets a property the view Loader reads whenever it is
    // built; it must not build anything itself.
    root.view = "account"
    compare(root.contentBuilt, 0)
    root.view = "list"
  }

  function test_opening_builds_it_once_and_measures_it_straight_away() {
    root.opened = true
    // Loaders are synchronous, so this all happened inside the property
    // change: the card measures the real header, view and footer on the frame
    // it fades in on, with no one-frame size pop.
    verify(headerLoader.item !== null, "header built during onOpenedChanged")
    verify(contentLoader.item !== null, "content built during onOpenedChanged")
    verify(footerLoader.item !== null, "footer built during onOpenedChanged")
    compare(root.headerBuilt, 1)
    compare(root.contentBuilt, 1)
    compare(root.footerBuilt, 1)
    verify(root.viewItem !== null)
    compare(root.viewItem.kind, "list")
    compare(root.listCount, 7)
    verify(root.popupHeaderHeight >= 105, "header measured: " + root.popupHeaderHeight)
    compare(root.popupColumnHeight, root.listHeight, "the view alone")
    verify(root.popupFooterHeight >= 35, "footer measured: " + root.popupFooterHeight)
    // The card takes header + gap + view + gap + footer, so a short view is
    // still a short card; the Flickable scrolls the view alone, and neither
    // the header nor the footer can be scrolled out from under it.
    compare(root.popupContentHeight,
      root.popupHeaderHeight + 10 + root.popupColumnHeight + 10 + root.popupFooterHeight)
    compare(panelFlick.contentHeight, root.popupColumnHeight)
    // The Loader carries the width down to the column, which the rows inside
    // it take from their parent — the column no longer sets it itself.
    compare(contentLoader.width, panelFlick.width)
    compare(contentLoader.item.width, panelFlick.width)
    compare(contentLoader.item.children[0].width, panelFlick.width)
    compare(headerLoader.item.width, keyCatcher.width)

    // Loaded once, kept: a panel opened once is one the user opens again.
    root.opened = false
    verify(headerLoader.item !== null)
    verify(contentLoader.item !== null)
    verify(footerLoader.item !== null)
    root.opened = true
    compare(root.headerBuilt, 1, "reopening rebuilds nothing")
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

  function test_the_header_and_the_footer_stay_put_while_a_tall_view_scrolls() {
    root.opened = true
    // Both blocks are siblings of the Flickable, not things inside its
    // content: that is what keeps them out of the scroll.
    compare(headerLoader.parent, keyCatcher)
    compare(footerLoader.parent, keyCatcher)
    compare(contentLoader.parent, panelFlick.contentItem)
    compare(headerLoader.mapToItem(keyCatcher, 0, 0).y, 0)
    var restingY = footerLoader.mapToItem(keyCatcher, 0, 0).y
    compare(restingY + footerLoader.height, keyCatcher.height)
    compare(panelFlick.height, keyCatcher.height - headerLoader.height - 10 - footerLoader.height)
    compare(panelFlick.mapToItem(keyCatcher, 0, 0).y, headerLoader.height + 10)

    // A view taller than the card: it now overflows the Flickable. A Column
    // re-measures itself on the next polish, not on the assignment.
    root.listHeight = 800
    tryVerify(function() { return panelFlick.contentHeight > panelFlick.height }, 2000,
      "the view must outgrow the viewport")
    compare(panelFlick.contentHeight, root.popupColumnHeight)
    var columnTop = contentLoader.mapToItem(keyCatcher, 0, 0).y

    panelFlick.contentY = panelFlick.contentHeight - panelFlick.height
    verify(panelFlick.contentY > 0, "the flickable scrolled")
    // The view moved by exactly what was scrolled; neither block moved at all,
    // and they are still sitting on the two edges of the card.
    compare(contentLoader.mapToItem(keyCatcher, 0, 0).y, columnTop - panelFlick.contentY)
    compare(headerLoader.mapToItem(keyCatcher, 0, 0).y, 0)
    compare(footerLoader.mapToItem(keyCatcher, 0, 0).y, restingY)
    compare(restingY + footerLoader.height, keyCatcher.height)
    // And the scrolled view stays between them, under neither.
    verify(columnTop >= headerLoader.height + 10 - 0.5)
    verify(columnTop - panelFlick.contentY + panelFlick.contentHeight <= restingY + 0.5)

    root.listHeight = 40
  }
}
