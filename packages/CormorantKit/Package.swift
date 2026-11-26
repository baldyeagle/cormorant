// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CormorantKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "CormorantCore", targets: ["CormorantCore"]),
        .library(name: "CormorantBlocking", targets: ["CormorantBlocking"]),
        .library(name: "CormorantAI", targets: ["CormorantAI"]),
        .library(name: "CormorantSync", targets: ["CormorantSync"]),
        .library(name: "CormorantBrowser", targets: ["CormorantBrowser"]),
        // For tests only (the apps' test targets and this package's): never linked into an app.
        .library(name: "CormorantTestSupport", targets: ["CormorantTestSupport"]),
    ],
    targets: [
        .target(name: "CormorantCore"),
        .target(name: "CormorantBlocking", dependencies: ["CormorantCore"]),
        .target(name: "CormorantAI", dependencies: ["CormorantCore"]),
        .target(name: "CormorantSync", dependencies: ["CormorantCore"]),
        // The browser engine the apps share: the store, tabs and their web views, downloads, icons.
        // Isolated to the main actor by default, as the apps are, with their approachable-concurrency
        // features, so code moves between an app and here unchanged.
        .target(
            name: "CormorantBrowser",
            dependencies: ["CormorantCore", "CormorantBlocking", "CormorantSync"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(name: "CormorantTestSupport", dependencies: ["CormorantSync"]),

        .testTarget(name: "CormorantCoreTests", dependencies: ["CormorantCore"]),
        .testTarget(name: "CormorantBlockingTests", dependencies: ["CormorantBlocking"], resources: [.copy("Resources")]),
        .testTarget(name: "CormorantAITests", dependencies: ["CormorantAI"]),
        .testTarget(name: "CormorantSyncTests", dependencies: ["CormorantSync", "CormorantTestSupport"]),
        .testTarget(name: "CormorantBrowserTests", dependencies: ["CormorantBrowser", "CormorantTestSupport"]),
        .testTarget(name: "CormorantTestSupportTests", dependencies: ["CormorantTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
