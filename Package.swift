// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Showtell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Showtell", targets: ["Showtell"]),
        .executable(name: "showtell-cli", targets: ["showtell-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
    ],
    targets: [
        .target(name: "ShowtellCore"),
        .executableTarget(
            name: "Showtell",
            dependencies: ["ShowtellCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "showtell-cli", dependencies: ["ShowtellCore"]),
        .testTarget(name: "ShowtellCoreTests", dependencies: ["ShowtellCore"]),
    ],
    swiftLanguageModes: [.v5]
)
