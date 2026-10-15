import Foundation

enum LooiAIRequest {
    static func companionReply(_ raw: String, allowedScenarios: Set<String>) -> (text: String, scenario: String?) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```(?:json)?\\s*|\\s*```$", with: "", options: .regularExpression)
        guard let data = cleaned.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { return (raw, nil) }
        let scenario = object["scenario"] as? String
        return (text, scenario.flatMap { allowedScenarios.contains($0) ? $0 : nil })
    }
    static func isStopRequest(_ text: String) -> Bool {
        let value = text.lowercased().filter { !$0.isWhitespace && !"，。！？,.!?".contains($0) }
        return ["停", "停止", "请停止", "stop"].contains(value) || ["停下", "别动", "停止移动", "停止运动", "不要移动", "stopmoving"].contains(where: value.contains)
    }
    static func identifier(_ text: String) throws -> String {
        guard !text.isEmpty, text.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw LooiError.message("模型、项目或区域名称无效") }
        return text
    }
    static func text(_ config: LooiAIConfiguration, key: String, prompt: String, image: Data? = nil) throws -> URLRequest {
        var headers = ["Content-Type": "application/json"]
        let url: String
        var body: [String: Any]
        if ["gemini", "vertex"].contains(config.provider) {
            let model = try identifier(config.model.replacingOccurrences(of: "models/", with: ""))
            if config.provider == "gemini" { url = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent" }
            else if config.endpointType == "express" { url = "https://aiplatform.googleapis.com/v1/publishers/google/models/\(model):generateContent" }
            else {
                let region = try identifier(config.region), project = try identifier(config.projectId)
                let host = region == "global" ? "aiplatform.googleapis.com" : "\(region)-aiplatform.googleapis.com"
                url = "https://\(host)/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(model):generateContent"
            }
            if config.auth == "oauth" { headers["Authorization"] = "Bearer \(key)" } else { headers["x-goog-api-key"] = key }
            var parts: [[String: Any]] = [["text": prompt]]
            if let image { parts.append(["inlineData": ["mimeType": "image/jpeg", "data": image.base64EncodedString()]]) }
            body = ["contents": [["role": "user", "parts": parts]], "generationConfig": ["maxOutputTokens": 1024]]
        } else {
            let base = config.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var user: [String: Any] = ["role": "user", "content": prompt]
            if config.provider == "ollama" {
                url = base + "/api/chat"
                if let image { user["images"] = [image.base64EncodedString()] }
                body = ["model": config.model, "messages": [user], "stream": false]
            } else {
                url = base + "/chat/completions"
                if !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
                if let image { user["content"] = [["type": "text", "text": prompt], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]]] }
                body = ["model": config.model, "messages": [user], "max_tokens": 1024]
            }
        }
        if config.provider == "qwen" { body["enable_thinking"] = false }
        guard let target = URL(string: url), ["http", "https"].contains(target.scheme), let host = target.host, !host.isEmpty,
              target.user == nil, target.password == nil else { throw LooiError.message("请填写有效的模型服务地址") }
        if target.scheme == "http" {
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            let privateIPv4 = octets.count == 4 && (octets[0] == 10 || octets[0] == 127 || octets[0] == 192 && octets[1] == 168 || octets[0] == 172 && (16...31).contains(octets[1]))
            let local = host == "localhost" || host == "::1" || host.hasSuffix(".local") || privateIPv4
            guard local else { throw LooiError.message("公网模型服务必须使用 HTTPS") }
        }
        var request = URLRequest(url: target); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.allHTTPHeaderFields = headers; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func response(_ data: Data, status: Int, provider: String) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let detail = (object["error"] as? [String: Any])?["message"] as? String ?? "检查模型、权限、配额和网络后重试"
            throw LooiError.message("AI 请求失败（\(status)）：\(redact(detail))")
        }
        let text: String?
        if ["gemini", "vertex"].contains(provider) {
            let candidates = object["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            text = (content?["parts"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        } else if provider == "ollama" { text = (object["message"] as? [String: Any])?["content"] as? String }
        else { text = (((object["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any])?["content"] as? String }
        guard let text, !text.isEmpty else { throw LooiError.message("模型未返回有效内容，请确认模型支持当前输入") }
        return text
    }
    static func redact(_ value: String) -> String {
        value.replacingOccurrences(of: "AIza[\\w-]+", with: "[已隐藏]", options: .regularExpression)
            .replacingOccurrences(of: "Bearer\\s+\\S+", with: "Bearer [已隐藏]", options: .regularExpression)
    }
}
