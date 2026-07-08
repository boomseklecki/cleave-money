// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CleaveAPI",
    platforms: [
        .iOS("26.0"),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CleaveAPI", targets: ["CleaveAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/plaid/plaid-link-ios-spm", from: "6.4.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS", from: "7.1.0")
    ],
    targets: [
        .target(
            name: "CleaveAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "LinkKit", package: "plaid-link-ios-spm", condition: .when(platforms: [.iOS])),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS", condition: .when(platforms: [.iOS]))
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        )
    ]
)
