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
        // llama.cpp's prebuilt framework runs the downloadable clean-up models (Metal included).
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11205/llama-b11205-xcframework.zip",
            checksum: "bbf935b50774634bd3ecbd601f98ddfc49342bbaf67010c23dd346d67e8a82eb"
        ),
        .executableTarget(
            name: "Showtell",
            dependencies: ["ShowtellCore", "llama", .product(name: "FluidAudio", package: "FluidAudio")],
            linkerSettings: [
                // Apple Intelligence's model is macOS 26 only; the app still starts on 14.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .executableTarget(name: "showtell-cli", dependencies: ["ShowtellCore"]),
        // Screens: Claude Code dialogs as herdr's pane.read (format ansi) returned them.
        .testTarget(name: "ShowtellCoreTests", dependencies: ["ShowtellCore"], resources: [.copy("Screens")]),
    ],
    swiftLanguageModes: [.v5]
)
