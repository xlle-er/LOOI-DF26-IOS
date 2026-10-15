import Foundation
import NaturalLanguage

enum LooiConversationLanguage {
    static func instruction(fallback: String) -> String {
        let name = fallback.hasPrefix("zh") ? "Simplified Chinese" : "English"
        return """
        <language_style>
        Follow the language explicitly requested by the user first. Otherwise respond in the language of the user's latest spoken or typed message. Apply this again on every turn, including language changes mid-conversation. For mixed-language input, follow the user's apparent preference. Do not translate or correct their input unless asked. The interface language must not override the user's language. Only when the user provides no clear language cue, use \(name) as the fallback. Keep speech natural and concise.
        </language_style>
        """
    }
    static func testPrompt(fallback: String) -> String {
        fallback.hasPrefix("zh") ? "请只说一次：你好，语音测试成功。" : "Say only once: Hello, the voice test succeeded."
    }
    static func offlineReply(to text: String, fallback: String) -> String {
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        let language = recognizer.dominantLanguage?.rawValue ?? fallback
        return language.hasPrefix("zh") ? "你好，我是 LOOI，很高兴和你待在一起。" : "Hello, I’m LOOI. It’s lovely to spend time with you."
    }
}
