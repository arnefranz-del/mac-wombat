// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wombat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Wombat", targets: ["Wombat"]),
        .executable(name: "WombatProbe", targets: ["WombatProbe"]),
    ],
    targets: [
        .target(name: "WombatCore"),
        .executableTarget(name: "Wombat", dependencies: ["WombatCore"]),
        .executableTarget(name: "WombatProbe", dependencies: ["WombatCore"]),
        .testTarget(name: "WombatCoreTests", dependencies: ["WombatCore"]),
        .testTarget(name: "WombatUITests", dependencies: ["Wombat", "WombatCore"]),
    ]
)
