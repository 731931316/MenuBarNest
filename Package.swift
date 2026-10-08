// swift-tools-version: 5.9
import PackageDescription

/// 使用系统框架构建菜单栏管理应用及核心规则测试，无第三方依赖。
let package = Package(
    name: "MenuBarNest",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MenuBarNest", targets: ["MenuBarNest"])],
    targets: [
        .target(name: "NestCore"),
        .executableTarget(name: "MenuBarNest", dependencies: ["NestCore"]),
        .testTarget(name: "NestCoreTests", dependencies: ["NestCore"]),
        .testTarget(name: "MenuBarSystemTests", dependencies: ["MenuBarNest"])
    ]
)
