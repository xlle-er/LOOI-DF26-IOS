import Foundation
import Combine

// Selection changes on the UI thread. Runtime services retain source messages;
// only presentation translates them, keeping device names and AI replies intact.
enum LooiAppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    var id: String { rawValue }
}

final class LooiLocalization: ObservableObject {
    static let shared = LooiLocalization()
    @Published var selection: LooiAppLanguage {
        didSet { defaults.set(selection.rawValue, forKey: "looi.app.language") }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = LooiAppLanguage(rawValue: defaults.string(forKey: "looi.app.language") ?? "system") ?? .system
    }
    static func resolve(_ selection: LooiAppLanguage, preferred: [String]) -> String {
        if selection != .system { return selection.rawValue }
        for language in preferred {
            if language.hasPrefix("zh") { return "zh-Hans" }
            if language.hasPrefix("en") { return "en" }
        }
        return "en"
    }
    var language: String {
        Self.resolve(selection, preferred: Bundle.main.preferredLocalizations + Locale.preferredLanguages)
    }
    var locale: Locale { Locale(identifier: language) }
    func refreshSystemLanguage() { if selection == .system { objectWillChange.send() } }
    #if SWIFT_PACKAGE
    private static let resources = Bundle.module
    #else
    private static let resources = Bundle(path: ProcessInfo.processInfo.environment["LOOI_TEST_BUNDLE"] ?? "") ?? .main
    #endif
    private static func table(_ language: String) -> [String: String] {
        guard let path = resources.path(forResource: language, ofType: "lproj"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return values
    }
    private static let english = table("en")
    static func string(_ key: String, language: String) -> String {
        language == "en" ? english[key] ?? key : key
    }
    static func message(_ source: String, language: String) -> String {
        guard language == "en" else { return source }
        if let exact = english[source] { return exact }
        // Dynamic service messages use source templates. Capture opaque names and
        // details; translate a nested detail only if it is another known message.
        for (key, translation) in english where key.contains("%@") {
            let pattern = "^" + key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "([\\s\\S]*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { continue }
            let arguments: [CVarArg] = (1..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: source) else { return "" }
                let value = String(source[range]); return english[value] ?? value
            }
            return String(format: translation, locale: Locale(identifier: language), arguments: arguments)
        }
        // Composite app errors may append a status suffix to a known source message.
        return english.filter { !$0.key.contains("%@") && $0.key.count > 3 }
            .sorted { $0.key.count > $1.key.count }
            .reduce(source) { result, pair in result.replacingOccurrences(of: pair.key, with: pair.value) }
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let language = LooiLocalization.shared.language
    let translated = LooiLocalization.string(key, language: language)
    return arguments.isEmpty ? translated : String(format: translated, locale: Locale(identifier: language), arguments: arguments)
}
func LM(_ message: String) -> String { LooiLocalization.message(message, language: LooiLocalization.shared.language) }
