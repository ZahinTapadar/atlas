// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ATLAS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ATLAS", targets: ["ATLAS"]),
        .executable(name: "atlas-nm-host", targets: ["AtlasNativeHost"]),
        .executable(name: "atlasctl", targets: ["AtlasCLI"]),
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
    ],
    targets: [
        // Pure, platform-light logic: storage, classification, windows, agent, scheduling.
        // Everything here is deterministic and unit-tested with fixtures.
        .target(
            name: "AtlasCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // macOS integrations: NSWorkspace, Accessibility, IOKit idle, EventKit,
        // notifications, launch-at-login. Thin adapters that feed AtlasCore.
        .target(
            name: "AtlasPlatform",
            dependencies: ["AtlasCore"]
        ),
        // SwiftUI application.
        .executableTarget(
            name: "ATLAS",
            dependencies: ["AtlasCore", "AtlasPlatform"]
        ),
        // Chrome/Firefox native-messaging host. Launched by the browser, writes
        // tab metadata into ATLAS's inbox directory, exits when the browser disconnects.
        .executableTarget(
            name: "AtlasNativeHost",
            dependencies: ["AtlasCore"]
        ),
        // `atlasctl` command-line tool and MCP server (stdio). Lets Claude — e.g. a scheduled check-in —
        // read tracked activity and record feedback, without ATLAS doing any planning itself.
        .executableTarget(
            name: "AtlasCLI",
            dependencies: ["AtlasCore"]
        ),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore"]
        ),
    ]
)
