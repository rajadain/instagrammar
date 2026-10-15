// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Instagrammar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Instagrammar", targets: ["Instagrammar"]),
        .executable(name: "tiler", targets: ["tiler"]),
    ],
    targets: [
        .target(name: "TilerCore"),
        .executableTarget(name: "Instagrammar", dependencies: ["TilerCore"]),
        .executableTarget(name: "tiler", dependencies: ["TilerCore"]),
        .testTarget(name: "TilerCoreTests", dependencies: ["TilerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
