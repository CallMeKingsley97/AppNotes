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
        let categories = CustomCategoryStore(directory: dataDirectory)
        let network = categories.create(name: "翻墙")!
        _ = categories.create(name: "设计与创作")
        let apps = [
            AppEntry(path: "/System/Applications/Notes.app", name: "Notes", bundleID: "com.apple.Notes",
                     version: "4.12", appStoreID: nil, storefrontCountryCode: nil),
            AppEntry(path: "/Applications/Pages.app", name: "Pages", bundleID: "com.apple.iWork.Pages",
                     version: "14.4", appStoreID: 409201541, storefrontCountryCode: "us"),
            AppEntry(path: "/Applications/Visual Studio Code.app", name: "Visual Studio Code — Development Workspace",
                     bundleID: "com.microsoft.VSCode", version: "1.100", appStoreID: nil, storefrontCountryCode: nil),
            AppEntry(path: "/Applications/Shadowrocket.app", name: "Shadowrocket", bundleID: "test.shadowrocket",
                     version: "1.0", appStoreID: nil, storefrontCountryCode: nil),
            AppEntry(path: "/Applications/Egern.app", name: "Egern", bundleID: "test.egern",
                     version: "1.0", appStoreID: nil, storefrontCountryCode: nil)
        ]
        let library = AppLibrary(apps: apps)
        categories.setMembership(apps[3], in: network, included: true)
        categories.setMembership(apps[4], in: network, included: true)
        let originalNote = "项目灵感与日常记录。\nCapture ideas, checklists, and things worth remembering.\n⌘N — 新建备忘录"
        notes.set(originalNote, for: apps[0].path)
        notes.flush()
        suggestions.set(AppSuggestion(text: "Create beautiful documents and collaborate with your team.",
                                      source: "appstore", title: "Pages", seller: "Apple", score: 1,
                                      appStoreID: 409201541), for: apps[1].path)
        suggestions.flush()
        let windows: [(String, NSWindow)] = [
            ("manager", window(AppRoot(preferences: preferences) {
                ManagerView(store: notes, suggestionStore: suggestions, library: library, detailsStore: detailsStore, categoryStore: categories,
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
                DetailView(app: apps[1], store: notes, suggestionStore: suggestions, detailsStore: detailsStore, categoryStore: categories)
                    .background(AppearanceProbe(state: appearanceStates["suggestion"]!))
            }, size: NSSize(width: 430, height: 780)))
        ]
        // Reuse these windows through every switch to exercise live observation, not just initial rendering.
        NSApp.activate(ignoringOtherApps: true)
        if !CommandLine.arguments.contains("--appearance-only") {
            try await verifyCategoryFlow(window: windows[0].1, store: categories, apps: apps)
        }
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
                    ("category-editor", window(AppRoot(preferences: preferences) {
                        CategoryEditor(store: categories, including: apps[3])
                    }, size: NSSize(width: 420, height: 250))),
                    ("category-apps", window(AppRoot(preferences: preferences) {
                        CategoryAppsEditor(store: categories, library: library, category: network)
                    }, size: NSSize(width: 540, height: 560))),
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
                    ("updates", window(AppRoot(preferences: preferences) {
                        AppUpdatesCard(updates: fixture.page?.releaseNotes ?? [], country: fixture.country, loading: false)
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
        precondition(CustomCategoryStore(directory: dataDirectory).apps(in: network, from: library.apps).count == 2)
        print("Passed: \(languages.count * 20) bilingual renders including categories, information, purchases, and unavailable states; 36 native/SwiftUI appearance checks covering manual → system, inherited changes, and reopened settings; persisted notes and categories unchanged.")
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

    @MainActor private func verifyCategoryFlow(window: NSWindow, store: CustomCategoryStore, apps: [AppEntry]) async throws {
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        // Operate AppKit controls in this process; SwiftUI drawing nodes may not expose AX children without an external client.
        guard let outline = nativeViews(in: window.contentView!, as: NSOutlineView.self).first else {
            throw AppearanceFailure(description: "Category sidebar was not rendered")
        }
        clickRow(outline, row: outline.numberOfRows - 1, x: 48)
        try await Task.sleep(for: .milliseconds(350))
        guard let sheet = window.sheets.first,
              let field = nativeViews(in: sheet.contentView!, as: NSTextField.self).first(where: { $0.isEditable }) else {
            throw AppearanceFailure(description: "Category naming sheet did not open")
        }
        sheet.makeFirstResponder(field)
        field.currentEditor()?.insertText("网络工具")
        try await Task.sleep(for: .milliseconds(150))
        pressKey(in: sheet, characters: "\r", keyCode: 36)
        try await Task.sleep(for: .milliseconds(350))
        guard let created = store.categories.first(where: { $0.name == "网络工具" }) else {
            throw AppearanceFailure(description: "Category name cannot be saved")
        }
        // SwiftUI uses custom button content, so locate the first action in the app-list column by its native frame.
        let split = nativeViews(in: window.contentView!, as: NSSplitView.self).first!
        let buttons = nativeViews(in: split.arrangedSubviews[1], as: NSButton.self)
        guard let manage = buttons.max(by: { $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY }) else {
            throw AppearanceFailure(description: "Manage Apps button was not rendered")
        }
        manage.performClick(nil)
        try await Task.sleep(for: .milliseconds(350))
        guard let picker = window.sheets.first,
              let table = nativeViews(in: picker.contentView!, as: NSTableView.self).first else {
            throw AppearanceFailure(description: "Manage Apps sheet did not open")
        }
        precondition(table.numberOfRows == apps.count)
        // SwiftUI checkbox gestures depend on the real pointer location. Exercise cancellation here;
        // persistence tests cover membership changes and the dedicated renders cover checkbox state.
        pressKey(in: picker, characters: "\u{1b}", keyCode: 53)
        try await Task.sleep(for: .milliseconds(350))
        guard window.sheets.isEmpty, store.apps(in: created, from: apps).isEmpty else {
            throw AppearanceFailure(description: "Cancelling Manage Apps changed category membership")
        }
        precondition(store.update(created, apps: apps, selectedPaths: [apps[3].path, apps[4].path]))
        try await Task.sleep(for: .milliseconds(350))
        guard let appTable = nativeViews(in: split.arrangedSubviews[1], as: NSTableView.self).first,
              appTable.numberOfRows == 2 else {
            throw AppearanceFailure(description: "The selected category did not show its two apps")
        }
        window.orderOut(nil)
        print("Passed: native UI creates and selects a category, opens and cancels Manage Apps, and refreshes its app list after membership changes.")
    }

    @MainActor private func nativeViews<T: NSView>(in root: NSView, as type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { nativeViews(in: $0, as: type) }
    }

    @MainActor private func clickRow(_ table: NSTableView, row: Int, x: CGFloat) {
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: x, y: rect.midY), to: nil)
        guard let window = table.window else { return }
        click(in: window, at: point)
    }

    @MainActor private func click(in window: NSWindow, at point: NSPoint) {
        window.makeKeyAndOrderFront(nil)
        // Queue the release before sending the press, so native tracking loops can consume it.
        for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseUp { NSApp.postEvent(event, atStart: true) }
            else { window.sendEvent(event) }
        }
    }

    @MainActor private func pressKey(in window: NSWindow, characters: String, keyCode: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: keyCode)!
        window.sendEvent(event)
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
