// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wax",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Wax", path: "Sources/Wax")
    ]
)
