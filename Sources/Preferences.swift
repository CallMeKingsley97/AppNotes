import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"

    var id: Self { self }

    func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            if language.hasPrefix("zh") { return "zh-Hans" }
            if language.hasPrefix("en") { return "en" }
        }
        return "en"
    }
}

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    static let didChange = Notification.Name("AppNotes.preferencesDidChange")

    @Published var appearance: AppAppearance {
        didSet { persist(appearance.rawValue, forKey: "appearance") }
    }
    @Published var language: AppLanguage {
        didSet { persist(language.rawValue, forKey: "language") }
    }
    @Published var hudEnabled: Bool {
        didSet { persist(hudEnabled, forKey: "hudEnabled") }
    }

    private let defaults: UserDefaults
    private let resourceBundle: Bundle

    init(defaults: UserDefaults = .standard, resourceBundle: Bundle = .main) {
        self.defaults = defaults
        self.resourceBundle = resourceBundle
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        hudEnabled = defaults.bool(forKey: "hudEnabled")
    }

    var locale: Locale { Locale(identifier: language.resolvedIdentifier()) }

    // Resolve the bundle explicitly so changing language also updates AppKit menus without restarting.
    func text(_ key: String, _ arguments: CVarArg...) -> String {
        let path = resourceBundle.path(forResource: language.resolvedIdentifier(), ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:)) ?? resourceBundle
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    private func persist(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

struct AppRoot<Content: View>: View {
    @ObservedObject var preferences: AppPreferences = .shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environmentObject(preferences)
            .environment(\.locale, preferences.locale)
            .preferredColorScheme(preferences.appearance.colorScheme)
            .tint(.accentColor)
    }
}
