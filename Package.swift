// swift-tools-version:5.8

import PackageDescription

let package = Package(
    name: "WasmKit",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "WasmKit",
            targets: ["WasmKit"]
        ),
        .library(
            name: "WASI",
            targets: ["WASI"]
        ),
        .library(
            name: "WIT", targets: ["WIT"]
        ),
        .executable(
            name: "wasmkit-cli",
            targets: ["CLI"]
        ),
        .library(name: "_CabiShims", targets: ["_CabiShims"]),
        .plugin(name: "WITOverlayPlugin", targets: ["WITOverlayPlugin"]),
        .plugin(name: "WITExtractorPlugin", targets: ["WITExtractorPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-system", .upToNextMinor(from: "1.1.1")),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-format.git", from: "508.0.1"),
    ],
    targets: [
        .executableTarget(
            name: "CLI",
            dependencies: [
                "WasmKit",
                "WASI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .target(
            name: "WasmKit",
            dependencies: [
                "SystemExtras",
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .target(
            name: "WASI",
            dependencies: ["WasmKit", "SystemExtras"]
        ),
        .target(
            name: "SystemExtras",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system")
            ]),
        .executableTarget(
            name: "Spectest",
            dependencies: [
                "WasmKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .target(name: "WIT"),
        .testTarget(name: "WITTests", dependencies: ["WIT"]),
        .target(name: "WITOverlayGenerator", dependencies: ["WIT"]),
        .target(name: "_CabiShims"),
        .plugin(name: "WITOverlayPlugin", capability: .buildTool(), dependencies: ["WITTool"]),
        .plugin(name: "GenerateOverlayForTesting", capability: .buildTool(), dependencies: ["WITTool"]),
        .testTarget(
            name: "WITOverlayGeneratorTests",
            dependencies: ["WITOverlayGenerator", "WasmKit", "WASI"],
            exclude: ["Fixtures", "Compiled", "Generated"],
            plugins: [.plugin(name: "GenerateOverlayForTesting")]
        ),
        .target(name: "WITExtractor"),
        .testTarget(
            name: "WITExtractorTests",
            dependencies: ["WITExtractor", "WIT"]
        ),
        .plugin(
            name: "WITExtractorPlugin",
            capability: .command(
                intent: .custom(verb: "extract-wit", description: "Extract WIT definition from Swift module"),
                permissions: []
            ),
            dependencies: ["WITTool"]
        ),
        .testTarget(
            name: "WITExtractorPluginTests",
            exclude: ["Fixtures"]
        ),
        .executableTarget(
            name: "WITTool",
            dependencies: [
                "WIT",
                "WITOverlayGenerator",
                "WITExtractor",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "WasmKitTests",
            dependencies: ["WasmKit"]
        ),
        .testTarget(
            name: "WASITests",
            dependencies: ["WASI"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
