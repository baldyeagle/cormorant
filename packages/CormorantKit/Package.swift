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
    ],
    targets: [
        .target(name: "CormorantCore"),
        .target(name: "CormorantBlocking", dependencies: ["CormorantCore"]),
        .target(name: "CormorantAI", dependencies: ["CormorantCore"]),
        .target(name: "CormorantSync", dependencies: ["CormorantCore"]),

        .testTarget(name: "CormorantCoreTests", dependencies: ["CormorantCore"]),
        .testTarget(name: "CormorantBlockingTests", dependencies: ["CormorantBlocking"]),
        .testTarget(name: "CormorantAITests", dependencies: ["CormorantAI"]),
        .testTarget(name: "CormorantSyncTests", dependencies: ["CormorantSync"]),
    ],
    swiftLanguageModes: [.v6]
)
