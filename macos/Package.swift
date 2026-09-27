// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TeslaCommander",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TeslaCommander", targets: ["TeslaCommander"])
    ],
    targets: [
        .executableTarget(
            name: "TeslaCommander",
            path: "Sources",
            exclude: ["Resources"]
        )
    ]
)
