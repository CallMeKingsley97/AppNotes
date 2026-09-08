import AppKit
import SwiftUI

private final class ReviewDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
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
        let notes = NotesStore(directory: dataDirectory)
        let suggestions = SuggestionStore(directory: dataDirectory)
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
                ManagerView(store: notes, suggestionStore: suggestions, library: library, onSettings: {}, onSearch: {})
            }, size: NSSize(width: 1080, height: 700))),
            ("settings", window(AppRoot(preferences: preferences) { SettingsView() }, size: NSSize(width: 520, height: 620))),
            ("search", window(AppRoot(preferences: preferences) {
                SearchOverlayView(store: notes, library: library, onClose: {})
            }, size: NSSize(width: 580, height: 430))),
            ("hud", window(AppRoot(preferences: preferences) {
                HUDView(appName: "Notes", note: originalNote, appPath: apps[0].path)
            }, size: NSSize(width: 390, height: 120))),
            ("suggestion", window(AppRoot(preferences: preferences) {
                DetailView(app: apps[1], store: notes, suggestionStore: suggestions)
            }, size: NSSize(width: 430, height: 780)))
        ]
        // Reuse these windows through every switch to exercise live observation, not just initial rendering.
        NSApp.activate(ignoringOtherApps: true)
        for language in [AppLanguage.chinese, .english] {
            preferences.language = language
            for appearance in [AppAppearance.light, .dark] {
                preferences.appearance = appearance
                NSApp.appearance = appearance.nativeAppearance
                for (name, window) in windows {
                    window.appearance = appearance.nativeAppearance
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
                precondition(notes.note(for: apps[0].path) == originalNote)
                precondition(NotesStore(directory: dataDirectory).note(for: apps[0].path) == originalNote)
            }
        }
        // Existing windows must also return to the system appearance.
        preferences.appearance = .system
        NSApp.appearance = preferences.appearance.nativeAppearance
        for (_, window) in windows { window.appearance = nil }
        precondition(preferences.appearance.nativeAppearance == nil)
        print("Passed: 20 native view renders, live language/theme switches, system appearance reset, and unchanged persisted notes.")
        print("Review images: \(output.path)")
    }

    @MainActor private func window<Content: View>(_ content: Content, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
