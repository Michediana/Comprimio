// swift-tools-version: 5.9
//
//  Motore di conversione per iOS: ImageMagick linkato nell'app e invocato
//  dentro il processo, perché su iOS `magick` non si può lanciare come
//  sottoprocesso. L'app Mac non lo usa. Vedi docs/ROADMAP-iOS.md.
//

import PackageDescription

let package = Package(
    name: "MagickEngine",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MagickEngine", targets: ["MagickEngine"])
    ],
    targets: [
        // Generato da Scripts/build-imagemagick-ios.sh.
        .binaryTarget(
            name: "ImageMagick",
            path: "../../Vendor/ImageMagick-iOS/ImageMagick.xcframework"
        ),
        .target(
            name: "MagickEngine",
            dependencies: ["ImageMagick"],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv")
            ]
        ),
        .testTarget(
            name: "MagickEngineTests",
            dependencies: ["MagickEngine"]
        )
    ]
)
