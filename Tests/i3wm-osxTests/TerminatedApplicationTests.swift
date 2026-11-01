import AppKit
import ApplicationServices
import XCTest
@testable import i3wm_osx

final class TerminatedApplicationTests: XCTestCase {
    func testMissedTerminationRemovesHiddenWindowsAndRelatedState() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        let manager = WindowManager()
        let workspace = manager.ledger.ensure(name: "4")
        manager.ledger.setCurrent(workspace)
        let entry = DiscoveredWindow(pid: pid, element: AXUIElementCreateApplication(pid), id: 900010, title: "", subrole: kAXDialogSubrole, frame: .zero)
        let window = try XCTUnwrap(manager.adopt(entry, into: workspace, recovering: true))
        window.hiddenByUs = true
        manager.fullscreenWindow = window.id
        manager.pendingOurHides[pid] = 2
        XCTAssertFalse(workspace.tree.collectWindows().isEmpty)
        XCTAssertTrue(manager.floatingWindows.contains(window.id))

        XCTAssertTrue(manager.pruneTerminatedApplications())

        XCTAssertTrue(workspace.tree.collectWindows().isEmpty)
        XCTAssertTrue(manager.nextUnusedWorkspace() === workspace)
        XCTAssertTrue(manager.windowsByID.isEmpty)
        XCTAssertTrue(manager.containerByWindowID.isEmpty)
        XCTAssertTrue(manager.floatingWindows.isEmpty)
        XCTAssertNil(manager.fullscreenWindow)
        XCTAssertNil(manager.pendingOurHides[pid])
        XCTAssertNil(manager.observers[pid])
        XCTAssertFalse(manager.pruneTerminatedApplications())
    }

    func testLiveHiddenOwnerSurvivesMissingGeometry() throws {
        let manager = WindowManager()
        defer {
            for observer in manager.observers.values {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        let workspace = manager.ledger.ensure(name: "7")
        let pid = getpid()
        let entry = DiscoveredWindow(pid: pid, element: AXUIElementCreateApplication(pid), id: 900011, title: "", subrole: nil, frame: nil)
        let window = try XCTUnwrap(manager.adopt(entry, into: workspace, recovering: true))
        window.hiddenByUs = true
        manager.pendingOurHides[pid] = 1

        XCTAssertFalse(manager.pruneTerminatedApplications())

        XCTAssertTrue(manager.windowsByID[window.id] === window)
        XCTAssertEqual(workspace.tree.collectWindows().map(\.id), [window.id])
        XCTAssertTrue(window.hiddenByUs)
        XCTAssertEqual(manager.pendingOurHides[pid], 1)
    }

    func testSweepRemovesOnlyConfirmedTerminatedOwners() throws {
        let manager = WindowManager()
        let first = manager.ledger.ensure(name: "4")
        let second = manager.ledger.ensure(name: "7")
        let firstEntry = DiscoveredWindow(pid: 100001, element: AXUIElementCreateApplication(100001), id: 900012, title: "", subrole: nil, frame: nil)
        let secondEntry = DiscoveredWindow(pid: 100002, element: AXUIElementCreateApplication(100002), id: 900013, title: "", subrole: nil, frame: nil)
        let dead = try XCTUnwrap(manager.adopt(firstEntry, into: first, recovering: true))
        let live = try XCTUnwrap(manager.adopt(secondEntry, into: second, recovering: true))
        dead.hiddenByUs = true
        live.hiddenByUs = true

        XCTAssertTrue(manager.pruneTerminatedApplications(isTerminated: { $0 == firstEntry.pid }))

        XCTAssertTrue(first.tree.collectWindows().isEmpty)
        XCTAssertEqual(second.tree.collectWindows().map(\.id), [live.id])
    }
}
