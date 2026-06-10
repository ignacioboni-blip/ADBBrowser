// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AdbBrowse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AdbBrowse",
            path: "Sources/AdbBrowse"
        )
    ]
)
