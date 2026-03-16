// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RiviumFlags",
    platforms: [
        .iOS(.v14),
        .macOS(.v12),
    ],
    products: [
        .library(name: "RiviumFlags", targets: ["RiviumFlags"]),
    ],
    targets: [
        .target(name: "RiviumFlags", path: "Sources/RiviumFlags"),
    ]
)
