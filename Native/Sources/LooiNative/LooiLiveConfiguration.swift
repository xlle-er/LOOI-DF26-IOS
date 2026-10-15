import Foundation

enum LooiLiveConfiguration {
    static func setup(_ original: [String: Any], model: String, testOnly: Bool) -> [String: Any] {
        var payload = original
        payload["model"] = model
        if testOnly {
            payload["tools"] = []
            payload["systemInstruction"] = ["parts": [["text": "这是扬声器连通性测试。只用中文说一次：你好，语音测试成功。说完立即结束，不要解释，不要调用工具。"]]]
            var generation = payload["generationConfig"] as? [String: Any] ?? [:]
            generation["maxOutputTokens"] = 256
            payload["generationConfig"] = generation
            payload["sessionResumption"] = [:]
        }
        return payload
    }
}
