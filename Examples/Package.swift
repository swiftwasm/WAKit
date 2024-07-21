// swift-tools-version:5.8

import PackageDescription

let package = Package(
    name: "Examples",
    platforms: [.macOS(.v10_13), .iOS(.v12)],
    dependencies: [
        .package(path: "../")
    ],
    targets: [
        .executableTarget(name: "Factorial", dependencies: [
            "WasmKit",
            .product(name: "WAT", package: "WasmKit")
        ]),
        .executableTarget(name: "PrintAdd", dependencies: [
            "WasmKit",
            .product(name: "WAT", package: "WasmKit")
        ]),
        .executableTarget(name: "WASI-Hello", dependencies: [
            "WasmKit",
            .product(name: "WasmKitWASI", package: "WasmKit"),
            .product(name: "WAT", package: "WasmKit"),
        ]),
    ]
)
