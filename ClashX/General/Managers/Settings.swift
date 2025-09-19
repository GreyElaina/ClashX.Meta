//
//  Settings.swift
//  ClashX
//
//  Created by yicheng on 2020/12/18.
//  Copyright © 2020 west2online. All rights reserved.
//

import Darwin
import Foundation
import Security

enum Settings {
    static let defaultMmdbDownloadUrl =
        "https://github.com/Dreamacro/maxmind-geoip/releases/latest/download/Country.mmdb"
    @UserDefault("mmdbDownloadUrl", defaultValue: defaultMmdbDownloadUrl)
    static var mmdbDownloadUrl: String

    @UserDefault("filterInterface", defaultValue: true)
    static var filterInterface: Bool

    @UserDefault("disableNoti", defaultValue: false)
    static var disableNoti: Bool

    @UserDefault("configAutoUpdateInterval", defaultValue: 48 * 60 * 60)
    static var configAutoUpdateInterval: TimeInterval

    static let proxyIgnoreListDefaultValue = [
        "192.168.0.0/16",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "127.0.0.1",
        "localhost",
        "*.local",
        "timestamp.apple.com",
        "sequoia.apple.com",
        "seed-sequoia.siri.apple.com",
    ]
    @UserDefault("proxyIgnoreList", defaultValue: proxyIgnoreListDefaultValue)
    static var proxyIgnoreList: [String]

    @UserDefault("disableMenubarNotice", defaultValue: false)
    static var disableMenubarNotice: Bool

    @UserDefault("proxyPort", defaultValue: 0)
    static var proxyPort: Int

    @UserDefault("apiPort", defaultValue: 0)
    static var apiPort: Int

    @UserDefault("apiPortAllowLan", defaultValue: false)
    static var apiPortAllowLan: Bool

    @UserDefault("hasLaunchedBefore", defaultValue: false)
    static var hasLaunchedBefore: Bool

    // 生成加密安全的随机数
    private static func generateSecureRandomBytes(count: Int) -> Data? {
        var randomBytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &randomBytes)
        return result == errSecSuccess ? Data(randomBytes) : nil
    }

    // 检查端口是否可用
    private static func isPortAvailable(_ port: Int) -> Bool {
        let socketFileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFileDescriptor != -1 else { return false }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        close(socketFileDescriptor)
        return bindResult == 0
    }

    // 查找可用端口
    private static func findAvailablePort(startingFrom startPort: Int = 10000) -> Int {
        let maxPort = 65535
        let attempts = 100

        for i in 0..<attempts {
            let port = (startPort - 1 + i) % maxPort + 1
            if port < 10000 { continue }
            if isPortAvailable(port) {
                return port
            }
        }

        // 如果找不到可用端口，回退到默认值
        Logger.log("Failed to find available port, using fallback", level: .warning)
        return Int.random(in: 10000..<65535)
    }

    // 生成加密安全的 API 密钥
    private static func generateSecureAPISecret(length: Int = 32) -> String {
        let charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        var secret = ""

        for _ in 0..<length {
            guard let randomData = generateSecureRandomBytes(count: 1),
                let byte = randomData.first
            else {
                // 回退到系统随机数
                let randomChar = charset.randomElement()!
                secret.append(randomChar)
                continue
            }
            let index = Int(byte) % charset.count
            let randomChar = charset[charset.index(charset.startIndex, offsetBy: index)]
            secret.append(randomChar)
        }

        return secret
    }

    static func randomizeSettingsOnFirstLaunch() {
        guard !hasLaunchedBefore else { return }

        // 生成随机端口并检查可用性
        let proxyPort = findAvailablePort(startingFrom: Int.random(in: 10000..<65535))
        let apiPort = findAvailablePort(startingFrom: Int.random(in: 10000..<65535))

        // 生成安全随机 API 密钥
        let secret = generateSecureAPISecret()

        // 应用随机设置
        Settings.proxyPort = proxyPort
        Settings.apiPort = apiPort
        Settings.apiSecret = secret
        Settings.apiPortAllowLan = false

        // 标记为已启动
        hasLaunchedBefore = true

        Logger.log("First launch: randomized proxy port to \(proxyPort), API port to \(apiPort)")
    }

    @UserDefault("disableSSIDList", defaultValue: [])
    static var disableSSIDList: [String]

    @UserDefault("enableIPV6", defaultValue: false)
    static var enableIPV6: Bool

    static let apiSecretKey = "api-secret"

    static var isApiSecretSet: Bool {
        return UserDefaults.standard.object(forKey: apiSecretKey) != nil
    }

    @UserDefault(apiSecretKey, defaultValue: "")
    static var apiSecret: String

    @UserDefault("overrideConfigSecret", defaultValue: false)
    static var overrideConfigSecret: Bool

    @UserDefault("kBuiltInApiMode", defaultValue: true)
    static var builtInApiMode: Bool

    static let disableShowCurrentProxyInMenu = !AppDelegate.isAboveMacOS14

    static let defaultBenchmarkUrl = "http://cp.cloudflare.com/generate_204"
    @UserDefault("benchMarkUrl", defaultValue: defaultBenchmarkUrl)
    static var benchMarkUrl: String {
        didSet {
            if benchMarkUrl.isEmpty {
                benchMarkUrl = defaultBenchmarkUrl
            }
        }
    }

    @UserDefault("kDisableRestoreProxy", defaultValue: false)
    static var disableRestoreProxy: Bool
}
