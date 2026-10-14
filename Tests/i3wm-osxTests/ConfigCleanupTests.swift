import XCTest
@testable import i3wm_osx

final class ConfigCleanupTests: XCTestCase {
    func testIgnoredDirectivesPreserveRawConfigAndSupportedSettings() throws {
        let raw = """
        font pango:monospace 10
        default_border pixel 2
        focus_on_window_activation urgent
        floating_modifier Mod4
        client.background "#112233"
        client.focused "#112233" "#223344" "#334455" "#445566" "#556677"
        gaps inner 8
        gaps outer 4
        smart_gaps on
        workspace_auto_back_and_forth yes
        mouse_warping focus
        bar {
            tray_padding 5
            status_command printf status
            workspace_min_width 32
            position bottom
            font pango:monospace 12
            colors {
                urgent_workspace #112233 #223344 #334455
                background #445566
                focused_workspace #556677 #667788 #778899
            }
        }
        bindsym Mod4+Return exec terminal
        """
        let config = try I3Config.parse(raw, path: "/tmp/i3-cleanup-test.conf")

        XCTAssertEqual(config.rawText, raw)
        XCTAssertEqual(config.sourcePath, "/tmp/i3-cleanup-test.conf")
        XCTAssertEqual(config.innerGap, 8)
        XCTAssertEqual(config.outerGap, 4)
        XCTAssertTrue(config.smartGaps)
        XCTAssertTrue(config.workspaceAutoBackAndForth)
        XCTAssertTrue(config.mouseFollowsFocus)
        XCTAssertEqual(config.bar.statusCommand, "printf status")
        XCTAssertEqual(config.bar.workspaceMinWidth, 32)
        XCTAssertEqual(config.bar.position, "bottom")
        XCTAssertEqual(config.bar.font, "pango:monospace 12")
        XCTAssertEqual(config.bar.colors.background, "#445566")
        XCTAssertEqual(config.bar.colors.focusedWorkspace, ["#556677", "#667788", "#778899"])
        XCTAssertEqual(config.bindings.map(\.commandText), ["exec terminal"])
    }

    func testReleaseBindingsStillAcceptOptionsAndSubstituteVariables() throws {
        let config = try I3Config.parse("""
        set $mod Mod4
        set $terminal terminal
        bindsym --release --locked $mod+Return exec --no-startup-id $terminal
        mode "resize" {
            bindsym --release Escape mode "default"
        }
        exec --no-startup-id $terminal
        exec_always --no-startup-id refresh
        """)

        XCTAssertEqual(config.bindings.map(\.keyspec), ["Mod4+Return"])
        XCTAssertEqual(config.bindings.map(\.commandText), ["exec --no-startup-id terminal"])
        let mode = try XCTUnwrap(config.modes.first)
        XCTAssertEqual(mode.name, "resize")
        XCTAssertEqual(mode.bindings.map(\.keyspec), ["Escape"])
        XCTAssertEqual(mode.bindings.map(\.commandText), ["mode \"default\""])
        XCTAssertEqual(config.execs.map(\.command), ["terminal", "refresh"])
        XCTAssertEqual(config.execs.map(\.once), [true, false])
    }

    func testExecOptionsKeepCommandAndQuotedSeparators() throws {
        for options in ["", "--no-startup-id ", "--no-startup-id --other-option "] {
            let commands = CommandParser.parse("exec \(options)printf 'one;two,three'; workspace 2")
            XCTAssertEqual(commands.count, 2)
            guard commands.count == 2 else { continue }
            guard case .exec(let command) = commands[0] else {
                XCTFail("Expected an exec command")
                continue
            }
            XCTAssertEqual(command, "printf one;two,three")
            guard case .workspace(let name) = commands[1] else {
                XCTFail("Expected a workspace command")
                continue
            }
            XCTAssertEqual(name, "2")
        }
    }
}
