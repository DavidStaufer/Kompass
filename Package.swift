// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kompass",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kompass",
            path: "Sources/Kompass"
        )
    ]
)
