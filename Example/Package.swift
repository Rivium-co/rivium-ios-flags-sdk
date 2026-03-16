// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RiviumFlagsExample",
    platforms: [.iOS(.v16), .macOS(.v13)],
    dependencies: [
        .package(path: "../"),
    ],
    targets: [
        .executableTarget(
            name: "RiviumFlagsExample",
            dependencies: [
                .product(name: "RiviumFlags", package: "rivium-flags-ios-sdk"),
            ],
            path: "RiviumFlagsExample"
        ),
    ]
)
