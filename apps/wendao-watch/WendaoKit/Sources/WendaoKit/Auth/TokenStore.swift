// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

#if canImport(Security)
    import Security
#endif

public enum TokenStoreError: Error, Sendable, Equatable {
    case keychain(Int32)
    case invalidData
}

/// 设备令牌存取。生产只用钥匙串；令牌绝不写入普通文件或 UserDefaults。
public protocol TokenStore: Sendable {
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
}

#if canImport(Security)
/// 钥匙串实现（通用密码项）。
///
/// 可访问性取「首次解锁后、仅本设备」：锁屏后的后台上传仍能读到令牌，且不随备份迁移到其他设备。
/// 手表的钥匙串与 iPhone 不互通，iPhone 绑定后经 WatchConnectivity 把令牌交给手表，由手表写入它自己的钥匙串。
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String = "com.wujilabs.wendao.device-token", account: String = "default",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func readToken() throws -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.invalidData
        }
        return token
    }

    public func writeToken(_ token: String) throws {
        let data = Data(token.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TokenStoreError.keychain(status) }
        var add = baseQuery()
        add.merge(attrs) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TokenStoreError.keychain(addStatus) }
    }

    public func deleteToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}

#endif

/// 内存实现，仅供测试与预览。
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func readToken() throws -> String? { lock.withLock { token } }
    public func writeToken(_ token: String) throws { lock.withLock { self.token = token } }
    public func deleteToken() throws { lock.withLock { token = nil } }
}
