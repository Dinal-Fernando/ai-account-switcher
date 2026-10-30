// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AIAccountSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
        .library(name: "SwitcherMac", targets: ["SwitcherMac"]),
        .executable(name: "aiswitch", targets: ["aiswitch"]),
        .executable(name: "AIAccountSwitcherApp", targets: ["AIAccountSwitcherApp"]),
    ],
    targets: [
        // Foundation-only logic: profiles, atomic switching, wrappers, usage decoding, scheduling, diagnostics.
        .target(name: "SwitcherCore", path: "Sources/SwitcherCore"),
        // macOS-only glue: Keychain-backed SecureStorage, Terminal launcher, launch-at-login, composition root.
        .target(name: "SwitcherMac", dependencies: ["SwitcherCore"], path: "Sources/SwitcherMac",
                linkerSettings: [.linkedFramework("Security"), .linkedFramework("ServiceManagement")]),
        // Command-line companion.
        .executableTarget(name: "aiswitch", dependencies: ["SwitcherCore", "SwitcherMac"], path: "Sources/aiswitch"),
        // The SwiftUI app. Built by Xcode (Xcode/AIAccountSwitcher.xcodeproj) or bundled by Scripts/build-app.sh.
        .executableTarget(name: "AIAccountSwitcherApp", dependencies: ["SwitcherCore", "SwitcherMac"], path: "Sources/AIAccountSwitcherApp",
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("UserNotifications"),
                                           .linkedFramework("Network"), .linkedFramework("Charts")]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"], path: "Tests/SwitcherCoreTests"),
    ]
)
