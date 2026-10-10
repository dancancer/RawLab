import Foundation
import Combine
import Security

struct AIConfiguration: Codable, Equatable {
    var baseURL = "https://api.deepseek.com"
    var model = "deepseek-flash"

    func normalizedURL() throws -> URL {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.utf8.count <= 2048,
              var components = URLComponents(string: address), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw AIError.message("API 地址必须是 HTTPS，且不能包含用户名、密码、查询参数或片段。")
        }
        components.scheme = "https"; components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw AIError.message("API 地址无效。") }
        return url
    }

    func endpoint(_ path: String) throws -> URL { try normalizedURL().appendingPathComponent(path) }

    func validated() throws -> Self {
        let url = try normalizedURL()
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw AIError.message("请填写有效的模型名称。")
        }
        return Self(baseURL: url.absoluteString, model: name)
    }
}

struct AIKeychain {
    var service = "com.rawlab.mac.ai-api"

    private func query(_ configuration: AIConfiguration) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: try configuration.normalizedURL().absoluteString]
    }

    func read(_ configuration: AIConfiguration) throws -> String? {
        var search = try query(configuration)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AIError.message("无法读取 Keychain 中的 API Key（\(status)）。")
        }
        return key
    }

    func save(_ key: String, configuration: AIConfiguration) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096, !value.contains(where: \.isWhitespace) else {
            throw AIError.message("API Key 不能为空或包含空白字符。")
        }
        let search = try query(configuration)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(search as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = search.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIError.message("无法保存 API Key 到 Keychain（\(status)）。") }
    }

    func remove(_ configuration: AIConfiguration) throws {
        let status = SecItemDelete(try query(configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIError.message("无法删除已保存的 API Key（\(status)）。")
        }
    }
}

final class AISettings: ObservableObject {
    @Published private(set) var configuration: AIConfiguration
    private let defaults: UserDefaults
    let keychain: AIKeychain
    private let storageKey = "rawlab.ai.configuration"

    init(defaults: UserDefaults = .standard, keychain: AIKeychain = AIKeychain()) {
        self.defaults = defaults; self.keychain = keychain
        configuration = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
    }

    func save(_ proposed: AIConfiguration, key: String) throws {
        let value = try proposed.validated()
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try keychain.save(key, configuration: value)
        } else if try keychain.read(value) == nil {
            throw AIError.message("此 API 地址还没有保存 API Key。")
        }
        defaults.set(try JSONEncoder().encode(value), forKey: storageKey)
        configuration = value
    }
}
