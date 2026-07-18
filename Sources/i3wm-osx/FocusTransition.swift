import CoreGraphics
import Darwin

struct SystemFocusSnapshot: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
}

enum ExternalFocusSource {
    case focusedWindowNotification
    case applicationActivation
    case applicationShown
}

enum ExternalFocusDecision: Equatable {
    case ignore
    case focusVisibleWorkspace
    case switchWorkspace(outputID: Int, outgoingWorkspaceName: String?)
}

enum FocusTransitionPolicy {
    static func decideExternalFocus(
        event: SystemFocusSnapshot,
        system: SystemFocusSnapshot?,
        targetWorkspaceName: String,
        targetOutputID: Int,
        activeWorkspaceByOutputID: [Int: String],
        source: ExternalFocusSource,
        targetIsHiddenOffscreen: Bool
    ) -> ExternalFocusDecision {
        guard event == system else { return .ignore }
        if activeWorkspaceByOutputID.values.contains(targetWorkspaceName) {
            return .focusVisibleWorkspace
        }
        if targetIsHiddenOffscreen {
            if case .applicationActivation = source {
                // Cmd-Tab, Dock clicks, and `open -a` can intentionally reveal
                // a soft-parked window.
            } else {
                return .ignore
            }
        }
        return .switchWorkspace(
            outputID: targetOutputID,
            outgoingWorkspaceName: activeWorkspaceByOutputID[targetOutputID]
        )
    }
}
