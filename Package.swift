// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ImageLoader",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "ImageLoader", targets: ["ImageLoader"]),
        .library(name: "ImageLoaderUI", targets: ["ImageLoaderUI"]),
        .library(name: "ImageLoaderTesting", targets: ["ImageLoaderTesting"]),
    ],
    targets: [
        .target(
            name: "ImageLoader",
            path: "Sources/ImageLoader"
        ),
        .target(
            name: "ImageLoaderUI",
            dependencies: ["ImageLoader"],
            path: "Sources/ImageLoaderUI"
        ),
        .target(
            name: "ImageLoaderTesting",
            dependencies: ["ImageLoader"],
            path: "Sources/ImageLoaderTesting"
        ),
        .testTarget(
            name: "ImageLoaderTests",
            dependencies: ["ImageLoader", "ImageLoaderTesting"],
            path: "Tests/ImageLoaderTests"
        ),
        .testTarget(
            name: "ImageLoaderUITests",
            dependencies: ["ImageLoader", "ImageLoaderUI", "ImageLoaderTesting"],
            path: "Tests/ImageLoaderUITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
