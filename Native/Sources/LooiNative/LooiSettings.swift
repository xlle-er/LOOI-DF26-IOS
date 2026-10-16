import Foundation
import Security
import Combine

struct LooiProvider: Identifiable {
    let id: String
    let title: String
    let endpoint: String
    let models: [String]
    let liveModels: [String]
    static let all: [LooiProvider] = [
        .init(id: "gemini", title: "Google Gemini", endpoint: "https://generativelanguage.googleapis.com", models: ["gemini-3.8-flash", "gemini-3.7-flash"], liveModels: ["gemini-3.8-live", "gemini-3.1-flash-live-preview"]),
        .init(id: "vertex", title: "Google Vertex AI", endpoint: "", models: ["gemini-3.8-flash"], liveModels: ["gemini-3.8-live", "gemini-3.1-flash-live-preview"]),
        .init(id: "qwen", title: "通义千问 / 百炼", endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1", models: ["qwen-plus", "qwen-flash", "qwen-vl-plus"], liveModels: []),
        .init(id: "groq", title: "Groq", endpoint: "https://api.groq.com/openai/v1", models: ["openai/gpt-oss-120b", "openai/gpt-oss-20b"], liveModels: []),
        .init(id: "fireworks", title: "Fireworks", endpoint: "https://api.fireworks.ai/inference/v1", models: ["accounts/fireworks/models/llama-v3p3-70b-instruct"], liveModels: []),
        .init(id: "ollama", title: "Ollama 本地模型", endpoint: "http://", models: ["qwen3:8b", "gemma3:4b"], liveModels: []),
        .init(id: "openai-compatible", title: "自定义兼容服务", endpoint: "https://", models: [], liveModels: []),
        .init(id: "rule", title: "离线陪伴", endpoint: "", models: [], liveModels: []),
        .init(id: "mock", title: "模拟演示", endpoint: "", models: [], liveModels: [])
    ]
    static func find(_ id: String) -> LooiProvider { all.first { $0.id == id } ?? all.first { $0.id == "rule" }! }
}

struct LooiAIConfiguration: Codable, Equatable {
    var provider = "gemini"
    var mode = "live"
    var auth = "apiKey"
    var endpointType = "standard"
    var baseUrl = "https://generativelanguage.googleapis.com"
    var projectId = ""
    var region = "global"
    var model = "gemini-3.8-flash"
    var liveModel = "gemini-3.8-live"
    var preset: LooiProvider { LooiProvider.find(provider) }
    var isLive: Bool { mode == "live" && !preset.liveModels.isEmpty }
    var isOffline: Bool { ["rule", "mock"].contains(provider) }
    var credentialRef: String { "looi.\(provider).key" }
    static func fresh(_ provider: String) -> Self {
        var value = Self(); let preset = LooiProvider.find(provider)
        value.provider = provider; value.baseUrl = preset.endpoint
        if provider == "vertex" { value.region = "us-central1" }
        value.model = preset.models.first ?? ""; value.liveModel = preset.liveModels.first ?? ""
        value.mode = preset.liveModels.isEmpty ? "text" : "live"
        return value
    }
    init() {}
    init(legacy: [String: Any], provider: String) {
        self = .fresh(provider)
        for key in ["mode", "auth", "endpointType", "baseUrl", "projectId", "region", "model", "liveModel"] {
            guard let text = legacy[key] as? String, !text.isEmpty else { continue }
            switch key {
            case "mode": mode = text
            case "auth": auth = text
            case "endpointType": endpointType = text
            case "baseUrl": baseUrl = text
            case "projectId": projectId = text
            case "region": region = text
            case "model": model = text
            default: liveModel = text.replacingOccurrences(of: "models/", with: "")
            }
        }
    }
}

enum LooiError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum LooiKeychain {
    private static let service = "org.example.looi.credentials"
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    static func read(_ key: String) throws -> String {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw LooiError.message("无法读取安全凭据，请解锁手机后重试") }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, key: String) throws {
        let q = query(key)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LooiError.message("无法保存安全凭据") }
        } else if status != errSecSuccess { throw LooiError.message("无法更新安全凭据") }
    }
    static func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LooiError.message("无法删除凭据") }
    }
}

final class LooiSettings: ObservableObject {
    @Published private(set) var configuration = LooiAIConfiguration()
    @Published var motionEnabled = false
    private var profiles: [String: LooiAIConfiguration] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateStoredScenes(defaults)
        if let data = defaults.data(forKey: "looi.native.profiles.v2"), let saved = try? JSONDecoder().decode([String: LooiAIConfiguration].self, from: data) {
            profiles = saved; configuration = saved[defaults.string(forKey: "looi.native.selected.v2") ?? "gemini"] ?? configuration
        } else if let json = defaults.string(forKey: "CapacitorStorage.looi.providers.v1"), let data = json.data(using: .utf8),
                  let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = old["profiles"] as? [String: [String: Any]] {
            profiles = entries.mapValues { .init(legacy: $0, provider: $0["provider"] as? String ?? "rule") }
            configuration = profiles[old["selected"] as? String ?? "rule"] ?? configuration
        }
    }
    private static func migrateStoredScenes(_ defaults: UserDefaults) {
        for (key, value) in defaults.dictionaryRepresentation() where key.lowercased().contains("scenario") && (key.hasPrefix("looi.") || key.hasPrefix("CapacitorStorage.looi.")) {
            let data = (value as? Data) ?? (value as? String)?.data(using: .utf8)
            let object: Any? = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? value
            guard let scenes = object as? [[String: Any]], !scenes.isEmpty, scenes.allSatisfy({ $0["steps"] is [[String: Any]] }) else { continue }
            let cleaned = scenes.compactMap { scene -> [String: Any]? in
                var result = scene
                let steps = (scene["steps"] as! [[String: Any]]).filter { ["move", "stop", "pause", "face", "expression"].contains($0["kind"] as? String ?? "") }
                guard steps.contains(where: { ["move", "face", "expression"].contains($0["kind"] as? String ?? "") }) else { return nil }
                result["steps"] = steps; result.removeValue(forKey: "usesHead")
                result["animationType"] = steps.contains(where: { $0["kind"] as? String == "move" }) ? "body" : "face"
                return result
            }
            if value is String, let encoded = try? JSONSerialization.data(withJSONObject: cleaned) { defaults.set(String(data: encoded, encoding: .utf8), forKey: key) }
            else if value is Data, let encoded = try? JSONSerialization.data(withJSONObject: cleaned) { defaults.set(encoded, forKey: key) }
            else { defaults.set(cleaned, forKey: key) }
        }
    }
    func profile(_ provider: String) -> LooiAIConfiguration { profiles[provider] ?? .fresh(provider) }
    func save(_ config: LooiAIConfiguration, key: String) throws {
        if !key.isEmpty { try LooiKeychain.save(key, key: config.credentialRef) }
        var updated = profiles; updated[config.provider] = config
        defaults.set(try JSONEncoder().encode(updated), forKey: "looi.native.profiles.v2")
        defaults.set(config.provider, forKey: "looi.native.selected.v2")
        profiles = updated; configuration = config
    }
}
