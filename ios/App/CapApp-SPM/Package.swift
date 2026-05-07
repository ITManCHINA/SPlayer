// swift-tools-version: 5.9
import PackageDescription

// DO NOT MODIFY THIS FILE - managed by Capacitor CLI commands
let package = Package(
    name: "CapApp-SPM",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapApp-SPM",
            targets: ["CapApp-SPM"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", exact: "8.3.1"),
        .package(name: "CapacitorFilesystem", path: "..\..\..\node_modules\.pnpm\@capacitor+filesystem@8.1.2_@capacitor+core@8.3.1\node_modules\@capacitor\filesystem"),
        .package(name: "CapacitorPreferences", path: "..\..\..\node_modules\.pnpm\@capacitor+preferences@8.0.1_@capacitor+core@8.3.1\node_modules\@capacitor\preferences"),
        .package(name: "ChoreruizCapacitorNodeJs", path: "..\..\..\node_modules\.pnpm\@choreruiz+capacitor-node-js@1.0.2_@capacitor+core@8.3.1\node_modules\@choreruiz\capacitor-node-js")
    ],
    targets: [
        .target(
            name: "CapApp-SPM",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "CapacitorFilesystem", package: "CapacitorFilesystem"),
                .product(name: "CapacitorPreferences", package: "CapacitorPreferences"),
                .product(name: "ChoreruizCapacitorNodeJs", package: "ChoreruizCapacitorNodeJs")
            ]
        )
    ]
)
