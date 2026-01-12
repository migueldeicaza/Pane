// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "pane",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "pane", targets: ["pane"])
    ],
    dependencies: [
    		  //        .package(url: "https://github.com/migueldeicaza/SwiftTerm", branch: "main"),
		  .package(path: "../SwiftTerm"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "pane",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ]
        )
    ]
)
