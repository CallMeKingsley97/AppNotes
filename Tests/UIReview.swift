import AppKit
import SwiftUI

private final class ReviewDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class AppearanceState {
    var colorScheme: ColorScheme?
}

private struct AppearanceProbe: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let state: AppearanceState

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { state.colorScheme = colorScheme }
}

private struct AppearanceFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct UIReview {
    static func main() {
        let app = NSApplication.shared
        let delegate = ReviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

private final class ReviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await review()
                NSApp.terminate(nil)
            } catch {
                fputs("UI review failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    @MainActor private func review() async throws {
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("appnotes-ui-review")
        let dataDirectory = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let preferences = AppPreferences(defaults: ReviewDefaults(suiteName: "AppNotes.UIReview")!)
        let appearanceStates = Dictionary(uniqueKeysWithValues:
            ["manager", "settings", "search", "hud", "suggestion"].map { ($0, AppearanceState()) })
        let notes = NotesStore(directory: dataDirectory)
        let suggestions = SuggestionStore(directory: dataDirectory)
        let detailsStore = AppDetailsStore(directory: dataDirectory, loader: FixtureDetailsLoader())
        let apps = [
            AppEntry(path: "/System/Applications/Notes.app", name: "Notes", bundleID: "com.apple.Notes",
                     version: "4.12", appStoreID: nil, storefrontCountryCode: nil),
            AppEntry(path: "/Applications/Pages.app", name: "Pages", bundleID: "com.apple.iWork.Pages",
                     version: "14.4", appStoreID: 409201541, storefrontCountryCode: "us"),
            AppEntry(path: "/Applications/Visual Studio Code.app", name: "Visual Studio Code — Development Workspace",
                     bundleID: "com.microsoft.VSCode", version: "1.100", appStoreID: nil, storefrontCountryCode: nil)
        ]
        let library = AppLibrary(apps: apps)
        let originalNote = "项目灵感与日常记录。\nCapture ideas, checklists, and things worth remembering.\n⌘N — 新建备忘录"
        notes.set(originalNote, for: apps[0].path)
        notes.flush()
        suggestions.set(AppSuggestion(text: "Create beautiful documents and collaborate with your team.",
                                      source: "appstore", title: "Pages", seller: "Apple", score: 1,
                                      appStoreID: 409201541), for: apps[1].path)
        suggestions.flush()
        let windows: [(String, NSWindow)] = [
            ("manager", window(AppRoot(preferences: preferences) {
                ManagerView(store: notes, suggestionStore: suggestions, library: library, detailsStore: detailsStore,
                            onSettings: {}, onSearch: {})
                    .background(AppearanceProbe(state: appearanceStates["manager"]!))
            }, size: NSSize(width: 1080, height: 700))),
            ("settings", window(AppRoot(preferences: preferences) {
                SettingsView().background(AppearanceProbe(state: appearanceStates["settings"]!))
            }, size: NSSize(width: 520, height: 620))),
            ("search", window(AppRoot(preferences: preferences) {
                SearchOverlayView(store: notes, library: library, onClose: {})
                    .background(AppearanceProbe(state: appearanceStates["search"]!))
            }, size: NSSize(width: 580, height: 430), useHostingView: true)),
            ("hud", window(AppRoot(preferences: preferences) {
                HUDView(appName: "Notes", note: originalNote, appPath: apps[0].path)
                    .background(AppearanceProbe(state: appearanceStates["hud"]!))
            }, size: NSSize(width: 390, height: 120), useHostingView: true)),
            ("suggestion", window(AppRoot(preferences: preferences) {
                DetailView(app: apps[1], store: notes, suggestionStore: suggestions, detailsStore: detailsStore)
                    .background(AppearanceProbe(state: appearanceStates["suggestion"]!))
            }, size: NSSize(width: 430, height: 780)))
        ]
        // Reuse these windows through every switch to exercise live observation, not just initial rendering.
        NSApp.activate(ignoringOtherApps: true)
        let languages: [AppLanguage] = CommandLine.arguments.contains("--appearance-only") ? [] : [.chinese, .english]
        for language in languages {
            preferences.language = language
            for appearance in [AppAppearance.light, .dark] {
                preferences.appearance = appearance
                NSApp.appearance = appearance.nativeAppearance
                for (name, window) in windows {
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let view = window.contentView!
                    view.layoutSubtreeIfNeeded()
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let path = output.appendingPathComponent("\(name)-\(language.rawValue)-\(appearance.rawValue).png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: path)
                    window.orderOut(nil)
                }
                let fixture = try DetailsFixtures.details(language: language.resolvedIdentifier())
                let cardWindows: [(String, NSWindow)] = [
                    ("information", window(AppRoot(preferences: preferences) {
                        AppInformationCard(app: DetailsFixtures.app, details: fixture,
                                           local: LocalAppDetails(copyright: "© 2026 Example Studio"))
                            .padding(24).frame(width: 430, height: 1100, alignment: .top)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }, size: NSSize(width: 430, height: 1100))),
                    ("purchases", window(AppRoot(preferences: preferences) {
                        InAppPurchasesCard(details: fixture, loading: false)
                            .padding(24).frame(width: 430, height: 430, alignment: .top)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }, size: NSSize(width: 430, height: 430))),
                    ("unavailable", window(AppRoot(preferences: preferences) {
                        VStack(spacing: 18) {
                            AppIntroductionCard(details: nil, suggestion: nil, loading: false)
                            AppInformationCard(app: apps[2], details: nil, local: LocalAppDetails())
                            InAppPurchasesCard(details: nil, loading: false)
                        }
                        .padding(24).frame(width: 430, height: 760, alignment: .top)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }, size: NSSize(width: 430, height: 760)))
                ]
                for (name, window) in cardWindows {
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(200))
                    let view = window.contentView!
                    view.layoutSubtreeIfNeeded()
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(
                        to: output.appendingPathComponent("\(name)-\(language.rawValue)-\(appearance.rawValue).png"))
                    window.close()
                }
                precondition(notes.note(for: apps[0].path) == originalNote)
                precondition(NotesStore(directory: dataDirectory).note(for: apps[0].path) == originalNote)
            }
        }
        // Match production: NSApp owns the override; every window and hosting view inherits it.
        preferences.appearance = .system
        NSApp.appearance = nil
        let systemAppearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])!
        for manual in [AppAppearance.dark, .light] {
            preferences.appearance = manual
            NSApp.appearance = manual.nativeAppearance
            try await verifyAppearance(manual.nativeAppearance!.name, windows: windows, states: appearanceStates,
                                       transition: manual.rawValue, output: output)
            preferences.appearance = .system
            NSApp.appearance = nil
            try await verifyAppearance(systemAppearance, windows: windows, states: appearanceStates,
                                       transition: "system-after-\(manual.rawValue)", output: output)
        }
        // Emulate inherited appearance changes inside this test process without changing macOS settings.
        for inherited in [NSAppearance.Name.darkAqua, .aqua] {
            NSApp.appearance = NSAppearance(named: inherited)
            try await verifyAppearance(inherited, windows: windows, states: appearanceStates,
                                       transition: "system-inherited-\(inherited.rawValue)", output: output)
        }
        NSApp.appearance = nil
        try await verifyAppearance(systemAppearance, windows: windows, states: appearanceStates,
                                   transition: "system-restored", output: output)
        let reopenedState = AppearanceState()
        let reopenedWindow = window(AppRoot(preferences: preferences) {
            SettingsView().background(AppearanceProbe(state: reopenedState))
        }, size: NSSize(width: 520, height: 620))
        try await verifyAppearance(systemAppearance, windows: [("settings", reopenedWindow)],
                                   states: ["settings": reopenedState], transition: "system-reopened", output: output)
        precondition(notes.note(for: apps[0].path) == originalNote)
        precondition(NotesStore(directory: dataDirectory).note(for: apps[0].path) == originalNote)
        print("Passed: \(languages.count * 16) bilingual renders including information, purchases, and unavailable states; 36 native/SwiftUI appearance checks covering manual → system, inherited changes, and reopened settings; persisted notes unchanged.")
        print("Review images: \(output.path)")
    }

    @MainActor private func verifyAppearance(_ expected: NSAppearance.Name, windows: [(String, NSWindow)],
                                             states: [String: AppearanceState], transition: String, output: URL) async throws {
        let expectedScheme: ColorScheme = expected == .darkAqua ? .dark : .light
        for (name, window) in windows {
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 200_000_000)
            let view = window.contentView!
            let windowAppearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            let contentAppearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            let scheme = states[name]!.colorScheme
            if name == "settings" {
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: output.appendingPathComponent("settings-\(transition).png"))
            }
            guard window.appearance == nil, view.appearance == nil,
                  windowAppearance == expected, contentAppearance == expected, scheme == expectedScheme else {
                throw AppearanceFailure(description: "\(transition), \(name): expected=\(expected.rawValue), window=\(windowAppearance?.rawValue ?? "nil"), content=\(contentAppearance?.rawValue ?? "nil"), SwiftUI=\(String(describing: scheme))")
            }
            window.orderOut(nil)
        }
    }

    @MainActor private func window<Content: View>(_ content: Content, size: NSSize, useHostingView: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        if useHostingView {
            window.contentView = NSHostingView(rootView: content)
        } else {
            window.contentViewController = NSHostingController(rootView: content)
        }
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
