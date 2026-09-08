import AppKit
import Foundation

// Keep tests independent of the user's preferences and notes.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main
struct PreferencesTests {
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let defaults = MemoryDefaults(suiteName: "AppNotes.InMemoryTests")!
        let preferences = AppPreferences(defaults: defaults, resourceBundle: bundle)
        precondition(preferences.appearance == .system)
        precondition(preferences.language == .system)
        precondition(!preferences.hudEnabled)
        precondition(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["zh-TW", "en-US"]) == "zh-Hans")
        precondition(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["en-GB", "zh-Hans"]) == "en")
        precondition(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["fr"]) == "en")
        precondition(AppLanguage.chinese.resolvedIdentifier(preferredLanguages: ["en"]) == "zh-Hans")
        precondition(AppAppearance.system.nativeAppearance == nil)
        precondition(AppAppearance.system.colorScheme == nil)
        precondition(AppAppearance.light.nativeAppearance?.name == .aqua)
        precondition(AppAppearance.dark.nativeAppearance?.name == .darkAqua)

        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: AppPreferences.didChange, object: preferences, queue: nil) { _ in
            notifications += 1
        }
        preferences.appearance = .dark
        preferences.language = .english
        preferences.hudEnabled = true
        NotificationCenter.default.removeObserver(token)
        precondition(notifications == 3)
        precondition(preferences.text("settings.title") == "Settings")
        precondition(preferences.text("detail.characters", 42) == "42 characters")
        let restored = AppPreferences(defaults: defaults, resourceBundle: bundle)
        precondition(restored.appearance == .dark && restored.language == .english && restored.hudEnabled)
        preferences.language = .chinese
        precondition(preferences.text("settings.title") == "设置")
        precondition(preferences.text("detail.characters", 42) == "42 字")
        precondition(preferences.text("fetch.progress", 3, 20) == "3 / 20")
        preferences.language = .english
        precondition(preferences.text("fetch.progress", 3, 20) == "3 of 20")
        defaults.set("unknown", forKey: "appearance")
        defaults.set("unknown", forKey: "language")
        let recovered = AppPreferences(defaults: defaults, resourceBundle: bundle)
        precondition(recovered.appearance == .system && recovered.language == .system)

        let english = try strings(in: bundle, language: "en")
        let chinese = try strings(in: bundle, language: "zh-Hans")
        precondition(Set(english.keys) == Set(chinese.keys), "Translation keys differ")
        let placeholders = try NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:l[du]|@|d|f)")
        for key in english.keys {
            let en = english[key]!
            let zh = chinese[key]!
            precondition(!en.isEmpty && !zh.isEmpty, "Empty translation: \(key)")
            let formats: (String) -> [String] = { value in
                placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value))
                    .map { (value as NSString).substring(with: $0.range) }.sorted()
            }
            precondition(formats(en) == formats(zh), "Format arguments differ: \(key)")
            preferences.language = .english
            precondition(preferences.text(key) == en, "English lookup failed: \(key)")
            preferences.language = .chinese
            precondition(preferences.text(key) == zh, "Chinese lookup failed: \(key)")
        }
        print("Passed: preferences, persistence round-trip, appearance mapping, language fallback, live language changes, and \(english.count) bilingual strings.")
    }

    private static func strings(in bundle: Bundle, language: String) throws -> [String: String] {
        let path = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language)!
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
    }
}
