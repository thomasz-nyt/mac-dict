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
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"])
            ]
        ),
        .target(
            name: "MacDictCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "MacDict",
            dependencies: ["MacDictCore"]
        ),
        .testTarget(
            name: "MacDictCoreTests",
            dependencies: ["MacDictCore"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
