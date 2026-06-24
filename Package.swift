// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v13)],
    targets: [
        // Real libghostty, built from ghostty source (zig 0.15.2) as an xcframework.
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        .executableTarget(
            name: "halo",
            dependencies: ["GhosttyKit", "HaloMux"],
            path: "Sources/Halo",
            resources: [.copy("Resources/Fonts")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOSurface"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Security"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "HaloMux",
            path: "Sources/HaloMux"
        ),
        .target(
            name: "CVterm",
            path: "Sources/CVterm",
            exclude: [
                "vendor/LICENSE",
                "vendor/VENDORING.txt",
                "vendor/fullwidth.inc",
                "vendor/encoding/DECdrawing.inc",
                "vendor/encoding/uk.inc",
            ],
            sources: ["vendor"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("vendor"), .headerSearchPath("include")]
        ),
        .executableTarget(
            name: "halod",
            dependencies: ["HaloMux", "CVterm"],
            path: "Sources/halod"
        ),
        .executableTarget(
            name: "halo-attach",
            dependencies: ["HaloMux"],
            path: "Sources/halo-attach"
        ),
    ]
)
