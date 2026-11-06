// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HerdrBarCore", targets: ["HerdrBarCore"]),
        .executable(name: "HerdrBar", targets: ["HerdrBar"]),
    ],
    targets: [
        .target(name: "HerdrBarCore"),
        .executableTarget(name: "HerdrBar", dependencies: ["HerdrBarCore"]),
        .testTarget(
            name: "HerdrBarCoreTests",
            dependencies: ["HerdrBarCore"],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6])
