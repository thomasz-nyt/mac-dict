// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MacDict",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacDict", targets: ["MacDict"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite"
        ),
        .target(
            name: "MacDictCore",
            dependencies: ["CSQLite"],
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .executableTarget(
            name: "MacDict",
            dependencies: ["MacDictCore"]
        ),
        .testTarget(
            name: "MacDictCoreTests",
            dependencies: ["MacDictCore"],
            resources: [.process("Fixtures")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
