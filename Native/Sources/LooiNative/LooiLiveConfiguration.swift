import Foundation

enum LooiLiveConfiguration {
    static func setup(_ original: [String: Any], model: String, testOnly: Bool) -> [String: Any] {
        var payload = original
        payload["model"] = model
        let language = LooiLocalization.shared.language
        let policy = LooiConversationLanguage.instruction(fallback: language)
        let originalParts = (payload["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var parts = originalParts.map { part -> [String: Any] in
            var result = part
            if let text = part["text"] as? String {
                result["text"] = text.replacingOccurrences(of: "(?s)<language_style>.*?</language_style>", with: "", options: .regularExpression)
            }
            return result
        }
        parts.append(["text": policy]); payload["systemInstruction"] = ["parts": parts]
        // Keep automatic speech-language detection; never pin speech to UI language.
        if var generation = payload["generationConfig"] as? [String: Any], var speech = generation["speechConfig"] as? [String: Any] {
            speech.removeValue(forKey: "languageCode"); generation["speechConfig"] = speech; payload["generationConfig"] = generation
        }
        if testOnly {
            payload["tools"] = []
            payload["systemInstruction"] = ["parts": [["text": "This is a speaker connectivity test. Say the exact sentence requested by the user once, then finish immediately. Do not explain or call tools. " + policy]]]
            var generation = payload["generationConfig"] as? [String: Any] ?? [:]
            generation["maxOutputTokens"] = 256
            payload["generationConfig"] = generation
            payload["sessionResumption"] = [:]
        }
        return payload
    }
}
