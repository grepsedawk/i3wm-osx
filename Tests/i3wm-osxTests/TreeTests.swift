import CoreGraphics
import XCTest
@testable import i3wm_osx

final class TreeTests: XCTestCase {
    private let context = LayoutContext(innerGap: 0, outerGap: 0, smartGaps: false, barInset: 0, barAtBottom: false)

    func testTabbedAndStackedFocusPlacesOnlyActiveSubtreeOnscreen() {
        for (layout, headerHeight) in [(Layout.tabbed, CGFloat(22)), (.stacking, CGFloat(36))] {
            let workspace = Container(kind: .workspace)
            workspace.layout = layout
            let first = Container(kind: .split)
            let second = Container(kind: .split)
            let nested = Container(kind: .split)
            workspace.add(first)
            workspace.add(second)
            first.add(nested)
            first.bumpFocus(nested)
            let available = CGRect(x: 50, y: 100, width: 400, height: 300)
            let visible = CGRect(x: 50, y: 100 + headerHeight, width: 400, height: 300 - headerHeight)
            let parked = CGRect(x: -10000, y: -10000, width: 400, height: 300 - headerHeight)

            LayoutEngine.compute(workspace: workspace, in: available, ctx: context)
            XCTAssertEqual(first.rect, visible)
            XCTAssertEqual(nested.rect, visible)
            XCTAssertEqual(second.rect, parked)
            XCTAssertTrue(workspace.deepestFocusedLeaf() === nested)

            workspace.bumpFocus(second)
            LayoutEngine.compute(workspace: workspace, in: available, ctx: context)
            XCTAssertEqual(first.rect, parked)
            XCTAssertEqual(nested.rect, parked)
            XCTAssertEqual(second.rect, visible)
            XCTAssertTrue(workspace.deepestFocusedLeaf() === second)
        }
    }

    func testShortContainersPreserveLayoutSpecificHeight() {
        for (layout, expectedHeight) in [(Layout.tabbed, CGFloat(-12)), (.stacking, CGFloat(0))] {
            let workspace = Container(kind: .workspace)
            workspace.layout = layout
            let child = Container(kind: .split)
            workspace.add(child)
            LayoutEngine.compute(workspace: workspace, in: CGRect(x: 0, y: 0, width: 100, height: 10), ctx: context)
            XCTAssertEqual(child.rect.size.height, expectedHeight)
        }
    }

    func testFocusFallsBackAfterRememberedChildIsRemoved() {
        let workspace = Container(kind: .workspace)
        let first = Container(kind: .split)
        let second = Container(kind: .split)
        workspace.add(first)
        workspace.add(second)
        workspace.bumpFocus(first)
        XCTAssertTrue(workspace.deepestFocusedLeaf() === first)
        workspace.remove(first)
        XCTAssertTrue(workspace.deepestFocusedLeaf() === second)
        workspace.remove(second)
        XCTAssertTrue(workspace.deepestFocusedLeaf() === workspace)
    }
}
