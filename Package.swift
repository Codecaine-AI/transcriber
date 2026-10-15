// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "TranscriberAPI", targets: ["TranscriberAPI"]),
    .executable(name: "transcriber-server", targets: ["TranscriberServer"]),
]
var targets: [Target] = [
    .target(name: "TranscriberDomain"),
    .target(name: "TranscriberAPIWire", dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"), .product(name: "HTTPTypes", package: "swift-http-types")]),
    .target(name: "TranscriberAPI", dependencies: ["TranscriberDomain", "TranscriberAPIWire"]),
    .target(name: "TranscriberServerKit", dependencies: ["TranscriberAPI", "TranscriberDomain", .product(name: "Hummingbird", package: "hummingbird"), .product(name: "Crypto", package: "swift-crypto")]),
    .executableTarget(name: "TranscriberServer", dependencies: ["TranscriberServerKit"]),
]

#if os(macOS)
products += [
    .executable(name: "Transcriber", targets: ["Transcriber"]),
    .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
]
targets += [
    .target(name: "TranscriberCore", dependencies: ["TranscriberDomain"]),
    .executableTarget(name: "Transcriber", dependencies: ["TranscriberCore", "TranscriberAPI"]),
]
#endif

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", exact: "1.11.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
