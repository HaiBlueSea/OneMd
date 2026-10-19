// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MarkView",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        // Expose MarkViewCore as a library so XcodeGen targets can depend on it
        .library(name: "MarkViewCore", targets: ["MarkViewCore"]),
        // App-layer logic shared by the GUI and native regression runner.
        .library(name: "MarkViewAppCore", targets: ["MarkViewAppCore"]),
        // GUI app — official xcodegen/xcodebuild path is blocked without full
        // Xcode; this executable is the local OneMd .app entry used by
        // scripts/build_mdos.py.
        .executable(name: "OneMd", targets: ["OneMd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark", from: "0.4.0"),
    ],
    targets: [
        // Core library with renderer and file watcher (no UI dependencies for testability)
        .target(
            name: "MarkViewCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/MarkViewCore",
            resources: [
                .process("Resources/template.html"),
                .process("Resources/prism-bundle.min.js"),
            ]
        ),
        // App-layer library: testable logic extracted from the Xcode app target
        // (JS bundle cache, status-bar stats model). No resources of its own —
        // reads MarkViewCore's resource bundle via ResourceBundle. Must never
        // create WKWebViews (headless CI would hang); view shells stay in the app target.
        .target(
            name: "MarkViewAppCore",
            dependencies: ["MarkViewCore"],
            path: "Sources/MarkViewAppCore"
        ),
        .executableTarget(
            name: "OneMd",
            dependencies: ["MarkViewCore", "MarkViewAppCore"],
            path: "Sources/MarkView",
            exclude: [
                "Info.plist",
                "MarkView.entitlements",
            ],
            resources: [
                .process("Resources/AppIcon.icns"),
            ]
        ),
    ]
)
