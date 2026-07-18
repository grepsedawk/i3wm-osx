import XCTest
@testable import i3wm_osx

final class FocusTransitionTests: XCTestCase {
    private let ghostty = SystemFocusSnapshot(pid: 10, windowID: 100)
    private let zen = SystemFocusSnapshot(pid: 20, windowID: 200)

    func testQueuedFocusEventIsIgnoredAfterSystemFocusChanges() {
        XCTAssertEqual(decide(event: ghostty, system: zen), .ignore)
    }

    func testSiblingWindowEventFromSameAppIsIgnored() {
        let otherZenWindow = SystemFocusSnapshot(pid: zen.pid, windowID: 201)
        XCTAssertEqual(decide(event: otherZenWindow, system: zen), .ignore)
    }

    func testTwoZenWindowsOnDifferentWorkspacesFollowFinalWindow() {
        let otherZenWindow = SystemFocusSnapshot(pid: zen.pid, windowID: 201)
        let decisions = [
            decide(event: otherZenWindow, system: zen, targetWorkspace: "3"),
            decide(event: zen, system: zen, targetWorkspace: "2", active: [1: "1", 2: "4"]),
        ]
        XCTAssertEqual(
            decisions,
            [.ignore, .switchWorkspace(outputID: 2, outgoingWorkspaceName: "4")]
        )
    }

    func testOffscreenZenSiblingFocusNotificationIsIgnored() {
        let offscreenSibling = SystemFocusSnapshot(pid: zen.pid, windowID: 201)
        XCTAssertEqual(
            decide(
                event: offscreenSibling,
                system: offscreenSibling,
                source: .focusedWindowNotification,
                targetIsHiddenOffscreen: true
            ),
            .ignore
        )
    }

    func testApplicationActivationCanRevealOffscreenWorkspace() {
        XCTAssertEqual(
            decide(
                event: zen,
                system: zen,
                source: .applicationActivation,
                targetIsHiddenOffscreen: true
            ),
            .switchWorkspace(outputID: 2, outgoingWorkspaceName: "2")
        )
    }

    func testApplicationShownCannotFollowOffscreenSibling() {
        XCTAssertEqual(
            decide(
                event: zen,
                system: zen,
                source: .applicationShown,
                targetIsHiddenOffscreen: true
            ),
            .ignore
        )
    }

    func testMatchingWindowIDFromDifferentAppIsIgnored() {
        let recycledID = SystemFocusSnapshot(pid: 30, windowID: zen.windowID)
        XCTAssertEqual(decide(event: recycledID, system: zen), .ignore)
    }

    func testMissingSystemFocusIsIgnored() {
        XCTAssertEqual(decide(event: zen, system: nil), .ignore)
    }

    func testVisibleWorkspaceOnlyUpdatesFocus() {
        XCTAssertEqual(
            decide(event: zen, system: zen, targetWorkspace: "2", active: [1: "1", 2: "2"]),
            .focusVisibleWorkspace
        )
    }

    func testHiddenWorkspaceReplacesOnlyItsOutputsWorkspace() {
        XCTAssertEqual(
            decide(event: zen, system: zen, targetWorkspace: "3", targetOutput: 2, active: [1: "1", 2: "2"]),
            .switchWorkspace(outputID: 2, outgoingWorkspaceName: "2")
        )
    }

    func testRapidCrossDisplaySequenceSettlesOnCurrentSystemFocus() {
        let active = [1: "1", 2: "2"]
        let decisions = [
            decide(event: ghostty, system: ghostty, targetWorkspace: "1", active: active),
            decide(event: zen, system: zen, targetWorkspace: "2", active: active),
            decide(event: ghostty, system: zen, targetWorkspace: "1", active: active),
        ]
        XCTAssertEqual(decisions, [.focusVisibleWorkspace, .focusVisibleWorkspace, .ignore])
    }

    func testRapidCrossDisplaySequenceWithTwoZenWindowsSettles() {
        let otherZenWindow = SystemFocusSnapshot(pid: zen.pid, windowID: 201)
        let active = [1: "1", 2: "2"]
        let decisions = [
            decide(event: zen, system: zen, targetWorkspace: "1", active: active),
            decide(event: otherZenWindow, system: otherZenWindow, targetWorkspace: "2", active: active),
            decide(event: zen, system: otherZenWindow, targetWorkspace: "1", active: active),
        ]
        XCTAssertEqual(decisions, [.focusVisibleWorkspace, .focusVisibleWorkspace, .ignore])
    }

    private func decide(
        event: SystemFocusSnapshot,
        system: SystemFocusSnapshot?,
        targetWorkspace: String = "3",
        targetOutput: Int = 2,
        active: [Int: String] = [1: "1", 2: "2"],
        source: ExternalFocusSource = .focusedWindowNotification,
        targetIsHiddenOffscreen: Bool = false
    ) -> ExternalFocusDecision {
        FocusTransitionPolicy.decideExternalFocus(
            event: event,
            system: system,
            targetWorkspaceName: targetWorkspace,
            targetOutputID: targetOutput,
            activeWorkspaceByOutputID: active,
            source: source,
            targetIsHiddenOffscreen: targetIsHiddenOffscreen
        )
    }
}
