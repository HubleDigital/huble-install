// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Huble",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Huble",
            path: "Sources/Huble"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
