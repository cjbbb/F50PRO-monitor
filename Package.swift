// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "F50Monitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "F50Monitor", targets: ["F50Monitor"])
    ],
    targets: [
        // 核心层：网络抓取、解析、状态模型、凭据存储、通知（可独立单测）
        .target(
            name: "F50Core",
            path: "Sources/F50Core"
        ),
        .executableTarget(
            name: "F50Monitor",
            dependencies: ["F50Core"],
            path: "Sources/F50Monitor",
            exclude: [
                "AppIcon.icns",
                "ChinaMobileLogo.svg",
                "ChinaUnicomLogo.svg",
                "ChinaTelecomLogo.svg",
                "ChinaBroadnetLogo.png"
            ]
        ),
        .testTarget(
            name: "F50MonitorTests",
            dependencies: ["F50Core"],
            path: "Tests/F50MonitorTests"
        )
    ]
)
