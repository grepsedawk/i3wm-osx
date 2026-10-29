import AppKit
import ApplicationServices
import XCTest
@testable import i3wm_osx

final class WindowRecoveryTests: XCTestCase {
    func testRecoveryOnlyQueriesOwnersOfUnknownOnscreenWindows() {
        let visible: [[String: Any]] = [
            windowInfo(id: 1, pid: 10),
            windowInfo(id: 2, pid: 20),
            windowInfo(id: 3, pid: 20),
            windowInfo(id: 0, pid: 30),
            windowInfo(id: 4, pid: 30, layer: 8),
            windowInfo(id: 5, pid: 30, size: CGSize(width: 20, height: 20)),
        ]
        let candidates = WindowDiscovery.recoveryCandidates(visible, excluding: [1])
        XCTAssertEqual(candidates.map(\.id), [2, 3])
        XCTAssertEqual(candidates.map(\.pid), [20, 20])
        XCTAssertTrue(WindowDiscovery.recoveryCandidates(visible, excluding: [1, 2, 3]).isEmpty)
    }

    func testStandardAndDialogWindowsBecomeEligibleAfterTheirGeometrySettles() {
        for subrole in [kAXStandardWindowSubrole, kAXDialogSubrole] {
            XCTAssertFalse(WindowDiscovery.isManageable(role: kAXWindowRole, subrole: subrole, size: .zero, minimized: false))
            XCTAssertTrue(WindowDiscovery.isManageable(role: kAXWindowRole, subrole: subrole, size: CGSize(width: 1132, height: 2089), minimized: false, modal: false))
        }
    }

    func testMinimizedAndUtilityWindowsRemainExcluded() {
        let size = CGSize(width: 800, height: 600)
        XCTAssertFalse(WindowDiscovery.isManageable(role: kAXWindowRole, subrole: kAXStandardWindowSubrole, size: size, minimized: true))
        XCTAssertFalse(WindowDiscovery.isManageable(role: kAXWindowRole, subrole: kAXDialogSubrole, size: size, minimized: false, modal: true))
        XCTAssertFalse(WindowDiscovery.isManageable(role: kAXWindowRole, subrole: kAXDialogSubrole, size: size, minimized: false, modal: nil))
        for subrole in [kAXUnknownSubrole, kAXSystemDialogSubrole, kAXFloatingWindowSubrole] {
            XCTAssertFalse(WindowDiscovery.isManageable(role: kAXWindowRole, subrole: subrole, size: size, minimized: false))
        }
        XCTAssertFalse(WindowDiscovery.isManageable(role: kAXApplicationRole, subrole: nil, size: size, minimized: false))
    }

    func testOrphanBelongsToWorkspaceOnOutputWithLargestOverlap() {
        let left = Workspace(name: "1", number: 1)
        let right = Workspace(name: "2", number: 2)
        let visible = [(left, CGRect(x: 0, y: 0, width: 1000, height: 800)),
                       (right, CGRect(x: 1000, y: 0, width: 1000, height: 800))]

        XCTAssertTrue(orphanWorkspace(frame: CGRect(x: 900, y: 50, width: 600, height: 500), visible: visible, fallback: left) === right)
        XCTAssertTrue(orphanWorkspace(frame: nil, visible: visible, fallback: left) === left)
        XCTAssertTrue(orphanWorkspace(frame: CGRect(x: -30000, y: -30000, width: 600, height: 500), visible: visible, fallback: right) === right)
    }

    func testRecoveryPreservesFocusSplitAndExistingWorkspaceOwnership() {
        let manager = WindowManager()
        defer { stopObserving(manager) }
        let source = manager.ledger.ensure(name: "1")
        let destination = manager.ledger.ensure(name: "2")
        manager.ledger.setCurrent(source)
        let element = AXUIElementCreateApplication(getpid())
        let existing = manager.adopt(element: element, pid: getpid(), id: 900001)!
        let focused = manager.focused
        let focusOrder = source.tree.focusOrder
        manager.pendingSplit = .vertical

        let recoveredEntry = DiscoveredWindow(pid: getpid(), element: element, id: 900002, title: "", subrole: kAXStandardWindowSubrole, frame: nil)
        let recovered = manager.adopt(recoveredEntry, into: source, recovering: true)!
        let recoveredContainer = manager.containerByWindowID[recovered.id]!
        XCTAssertTrue(manager.focused === focused)
        XCTAssertTrue(source.tree.deepestFocusedLeaf() === focused)
        XCTAssertEqual(source.tree.focusOrder, [recoveredContainer.id] + focusOrder)
        XCTAssertEqual(manager.pendingSplit, .vertical)
        XCTAssertTrue(manager.workspaceContaining(recoveredContainer) === source)
        XCTAssertTrue(manager.windowsByID[existing.id] === existing)

        manager.ledger.setCurrent(destination)
        let duplicate = manager.adopt(recoveredEntry, into: destination, recovering: true)
        XCTAssertTrue(duplicate === recovered)
        XCTAssertTrue(manager.workspaceContaining(recoveredContainer) === source)
        XCTAssertTrue(destination.tree.children.isEmpty)
        XCTAssertEqual(manager.windowsByID.count, 2)
    }

    func testRecoveryInEmptyWorkspaceDoesNotSetGlobalFocusOrConsumeSplit() {
        let manager = WindowManager()
        defer { stopObserving(manager) }
        let workspace = manager.ledger.ensure(name: "1")
        manager.ledger.setCurrent(workspace)
        manager.pendingSplit = .horizontal
        let element = AXUIElementCreateApplication(getpid())

        let entry = DiscoveredWindow(pid: getpid(), element: element, id: 900003, title: "", subrole: kAXStandardWindowSubrole, frame: nil)
        let window = manager.adopt(entry, into: workspace, recovering: true)!

        XCTAssertNil(manager.focused)
        XCTAssertEqual(manager.pendingSplit, .horizontal)
        XCTAssertEqual(workspace.tree.collectWindows().map(\.id), [window.id])
    }

    func testSlowDiscoveryDoesNotBlockMainQueueAndConcurrentScansAreCoalesced() {
        let manager = WindowManager()
        manager.ledger.setCurrent(manager.ledger.ensure(name: "1"))
        let started = expectation(description: "background discovery started")
        let responsive = expectation(description: "main queue responds during discovery")
        let finished = expectation(description: "background discovery finished")
        let gate = DispatchSemaphore(value: 0)
        let candidates = [WindowCandidate(pid: getpid(), id: 900004, frame: CGRect(x: 0, y: 0, width: 800, height: 600))]
        manager.recoverOrphanWindows(candidates: candidates) { _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = gate.wait(timeout: .now() + 2)
            finished.fulfill()
            return []
        }
        manager.recoverOrphanWindows(candidates: candidates) { _ in
            XCTFail("Overlapping recovery scan should be coalesced")
            return []
        }
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [started, responsive], timeout: 1)
        gate.signal()
        wait(for: [finished], timeout: 1)
    }

    func testRecoveredDialogsFloatUnlessRuleDisablesFloating() {
        let manager = WindowManager()
        defer { stopObserving(manager) }
        let workspace = manager.ledger.ensure(name: "1")
        let frame = CGRect(x: 50, y: 50, width: 800, height: 600)
        let element = AXUIElementCreateApplication(getpid())
        let dialog = DiscoveredWindow(pid: getpid(), element: element, id: 900005, title: "", subrole: kAXDialogSubrole, frame: frame)
        let floating = manager.adopt(dialog, into: workspace, recovering: true)!
        XCTAssertTrue(floating.isFloating)
        XCTAssertEqual(floating.savedFloatingFrame, frame)
        manager.config.forWindow = [ForWindowRule(criteria: [:], command: "floating disable")]
        let tiledDialog = DiscoveredWindow(pid: getpid(), element: element, id: 900006, title: "", subrole: kAXDialogSubrole, frame: frame)
        XCTAssertFalse(manager.adopt(tiledDialog, into: workspace, recovering: true)!.isFloating)
    }

    func testHiddenFloatingWindowRemainsParkedDuringLayout() {
        let manager = WindowManager()
        defer { stopObserving(manager) }
        let workspace = manager.ledger.ensure(name: "1")
        let frame = CGRect(x: 50, y: 50, width: 800, height: 600)
        let entry = DiscoveredWindow(pid: getpid(), element: AXUIElementCreateApplication(getpid()), id: 900007, title: "", subrole: kAXDialogSubrole, frame: frame)
        let window = manager.adopt(entry, into: workspace, recovering: true)!
        window.hiddenByUs = true
        let parked = CGRect(x: -30000, y: -30000, width: 800, height: 600)
        window.lastKnownFrame = parked

        manager.applyAllLayouts()

        XCTAssertEqual(window.lastKnownFrame, parked)
        XCTAssertTrue(window.hiddenByUs)
    }

    func testRecoveryRegistersVisibleSiblingBeforeHidingInactiveSibling() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Requires a display") }
        let manager = WindowManager()
        defer { stopObserving(manager) }
        let output = Output(screen: screen, id: 1)
        let hidden = manager.ledger.ensure(name: "1")
        let visible = manager.ledger.ensure(name: "2")
        hidden.output = output
        visible.output = output
        output.activeWorkspace = visible
        manager.outputs = [output]
        manager.ledger.setCurrent(visible)
        let element = AXUIElementCreateApplication(getpid())
        let frame = CGRect(x: 50, y: 50, width: 800, height: 600)
        let hiddenEntry = DiscoveredWindow(pid: getpid(), element: element, id: 900008, title: "", subrole: kAXDialogSubrole, frame: frame)
        let visibleEntry = DiscoveredWindow(pid: getpid(), element: element, id: 900009, title: "", subrole: kAXDialogSubrole, frame: frame)

        manager.absorbOrphanWindows([(hiddenEntry, hidden), (visibleEntry, visible)])

        XCTAssertEqual(manager.windowsByID.count, 2)
        XCTAssertNil(manager.pendingOurHides[getpid()])
        XCTAssertTrue(try XCTUnwrap(manager.windowsByID[hiddenEntry.id]).hiddenByUs)
        XCTAssertFalse(try XCTUnwrap(manager.windowsByID[visibleEntry.id]).hiddenByUs)
    }

    private func windowInfo(id: UInt32, pid: pid_t, layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600)) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer,
         kCGWindowBounds as String: CGRect(origin: .zero, size: size).dictionaryRepresentation]
    }

    private func stopObserving(_ manager: WindowManager) {
        for observer in manager.observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}
