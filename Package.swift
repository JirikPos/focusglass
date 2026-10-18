// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FocusGlass",
    platforms: [.macOS(.v14)],
    targets: [
        // Jádro převodů bez UI – testovatelné samostatně.
        .target(name: "ConvertKit"),
        .executableTarget(name: "FocusGlass", dependencies: ["ConvertKit"]),
        .testTarget(name: "ConvertKitTests", dependencies: ["ConvertKit"]),
    ]
)
