// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgyComputerUse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "agy-cu",
            path: "Sources/AgyComputerUse",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("QuartzCore"),
            ]
        )
    ]
)
