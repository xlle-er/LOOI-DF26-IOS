// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LooiNative",
    platforms: [.iOS(.v15)],
    products: [.library(name: "LooiNative", targets: ["LooiNative"])],
    dependencies: [.package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "9.0.0")],
    targets: [.target(name: "LooiNative", dependencies: [.product(name: "GoogleSignIn", package: "GoogleSignIn-iOS")],
                      resources: [.copy("Resources/Face"), .process("Resources/LiveSetup.json")])]
)
