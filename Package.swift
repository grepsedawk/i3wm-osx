// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "i3wm-osx",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "i3wm-osx",
            path: "Sources/i3wm-osx",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "i3-msg",
            path: "Sources/i3-msg"
        ),
        .testTarget(
            name: "i3wm-osxTests",
            dependencies: ["i3wm-osx"],
            path: "Tests/i3wm-osxTests"
        ),
    ]
)
