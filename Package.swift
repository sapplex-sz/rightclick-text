// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RightClickTextCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "RightClickTextCore", targets: ["RightClickTextCore"])],
    targets: [
        .target(name: "RightClickTextCore", path: "Sources/Core"),
        .testTarget(name: "CoreTests", dependencies: ["RightClickTextCore"], path: "Tests/CoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
