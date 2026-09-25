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
            ["manager", "settings", "search", "hud", "suggestion", "reminders", "watches"].map { ($0, AppearanceState()) })
        let notes = NotesStore(directory: dataDirectory)
        let suggestions = SuggestionStore(directory: dataDirectory)
        let detailsStore = AppDetailsStore(directory: dataDirectory, loader: FixtureDetailsLoader())
        let categories = CustomCategoryStore(directory: dataDirectory)
        let imports = ManualImportStore(directory: dataDirectory)
        let priceFixture = PriceFixtures.state()
        try JSONEncoder().encode(priceFixture).write(to: dataDirectory.appendingPathComponent("price-monitoring.json"))
        let monitor = PriceMonitorStore(directory: dataDirectory, loader: FixturePriceLoader())
        let reminderNavigation = MonitorNavigation()
        reminderNavigation.showReminders()
        let watchNavigation = MonitorNavigation()
        watchNavigation.showWatches(priceFixture.watches[0].id)
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
                            imports: imports, monitor: monitor, monitorNavigation: MonitorNavigation(), onSettings: {}, onSearch: {})
                    .background(AppearanceProbe(state: appearanceStates["manager"]!))
            }, size: NSSize(width: 1080, height: 700), manager: true)),
            ("settings", window(AppRoot(preferences: preferences) {
                SettingsView(monitor: monitor).background(AppearanceProbe(state: appearanceStates["settings"]!))
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
                DetailView(app: apps[1], store: notes, suggestionStore: suggestions, detailsStore: detailsStore, categoryStore: categories, monitor: monitor)
                    .background(AppearanceProbe(state: appearanceStates["suggestion"]!))
            }, size: NSSize(width: 430, height: 780))),
            ("reminders", window(AppRoot(preferences: preferences) {
                ManagerView(store: notes, suggestionStore: suggestions, library: library, detailsStore: detailsStore,
                            categoryStore: categories, imports: imports, monitor: monitor, monitorNavigation: reminderNavigation,
                            onSettings: {}, onSearch: {})
                    .background(AppearanceProbe(state: appearanceStates["reminders"]!))
            }, size: NSSize(width: 1080, height: 700), manager: true)),
            ("watches", window(AppRoot(preferences: preferences) {
                ManagerView(store: notes, suggestionStore: suggestions, library: library, detailsStore: detailsStore,
                            categoryStore: categories, imports: imports, monitor: monitor, monitorNavigation: watchNavigation,
                            onSettings: {}, onSearch: {})
                    .background(AppearanceProbe(state: appearanceStates["watches"]!))
            }, size: NSSize(width: 880, height: 580), manager: true))
        ]
        // Reuse these windows through every switch to exercise live observation, not just initial rendering.
        NSApp.activate(ignoringOtherApps: true)
        if !CommandLine.arguments.contains("--appearance-only") {
            let emptyMonitor = PriceMonitorStore(directory: dataDirectory.appendingPathComponent("empty"), loader: FixturePriceLoader())
            for language in [AppLanguage.english, .chinese] {
                preferences.language = language
                for appearance in [AppAppearance.dark, .light] {
                    preferences.appearance = appearance
                    NSApp.appearance = appearance.nativeAppearance
                    for size in [NSSize(width: 1080, height: 700), NSSize(width: 880, height: 580)] {
                        for (name, fixture) in [("populated", monitor), ("empty", emptyMonitor)] {
                            let layoutWindow = window(AppRoot(preferences: preferences) {
                                ManagerView(store: notes, suggestionStore: suggestions, library: library, detailsStore: detailsStore,
                                            categoryStore: categories, imports: imports, monitor: fixture,
                                            monitorNavigation: MonitorNavigation(), onSettings: {}, onSearch: {})
                            }, size: size, manager: true)
                            let scenario = "\(name)-\(language.rawValue)-\(appearance.rawValue)-\(Int(size.width))"
                            try await verifyWindowLayout(window: layoutWindow, scenario: scenario,
                                                         populated: name == "populated", output: output)
                            layoutWindow.close()
                        }
                    }
                }
            }
            // Layout clicks select fixture events; restore unread state for the behavioral checks below.
            await monitor.markRead(Set(priceFixture.events.filter(\.isUnread).map(\.id)), read: false)
            if CommandLine.arguments.contains("--window-layout-only") { return }
        }
        if !CommandLine.arguments.contains("--appearance-only") {
            try await verifyCategoryFlow(window: windows[0].1, store: categories, apps: apps)
        }
        if !CommandLine.arguments.contains("--appearance-only") {
            try await verifyMonitorFlow(window: windows.first { $0.0 == "reminders" }!.1,
                                        monitor: monitor, navigation: reminderNavigation)
            try await verifyWatchEditor(window: windows.first { $0.0 == "watches" }!.1, monitor: monitor)
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
                    ("watch-editor", window(AppRoot(preferences: preferences) {
                        PriceWatchEditor(monitor: monitor, existing: priceFixture.watches[0])
                    }, size: NSSize(width: 578, height: 550))),
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
            SettingsView(monitor: monitor).background(AppearanceProbe(state: reopenedState))
        }, size: NSSize(width: 520, height: 620))
        try await verifyAppearance(systemAppearance, windows: [("settings", reopenedWindow)],
                                   states: ["settings": reopenedState], transition: "system-reopened", output: output)
        precondition(notes.note(for: apps[0].path) == originalNote)
        precondition(NotesStore(directory: dataDirectory).note(for: apps[0].path) == originalNote)
        precondition(CustomCategoryStore(directory: dataDirectory).apps(in: network, from: library.apps).count == 2)
        print("Passed: bilingual light/dark renders including free offers, watches at minimum width and watch editor; native/SwiftUI appearance checks, persisted notes and categories unchanged.")
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

    @MainActor private func verifyWindowLayout(window: NSWindow, scenario: String, populated: Bool, output: URL) async throws {
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard let outline = nativeViews(in: window.contentView!, as: NSOutlineView.self).first else {
            throw AppearanceFailure(description: "Manager sidebar missing")
        }
        // Fixture sidebar: Library (0), All (1), Noted (2), Sources (3…7), Monitoring (8…10).
        for (name, row) in [("all", 1), ("offers", 9), ("watches", 10), ("all-again", 1), ("offers-again", 9), ("watches-again", 10)] {
            outline.scrollRowToVisible(row)
            clickRow(outline, row: row, x: 80)
            try await Task.sleep(for: .milliseconds(250))
            guard outline.selectedRow == row else {
                throw AppearanceFailure(description: "\(scenario), \(name): sidebar click did not select the requested page")
            }
            try verifyContentBounds(window, context: "\(scenario)-\(name)")
            if name == "offers" || name == "watches" {
                // Capture the real title bar and traffic lights, not only the hosting view.
                let frame = window.contentView!.superview!
                let image = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
                frame.cacheDisplay(in: frame.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(
                    to: output.appendingPathComponent("window-layout-\(scenario)-\(name).png"))
            }
            if populated && name.hasSuffix("-again") && row != 1 {
                let split = nativeViews(in: window.contentView!, as: NSSplitView.self).first!
                let table = nativeViews(in: split.arrangedSubviews[1], as: NSTableView.self).first!
                guard table.numberOfRows > 0 else { throw AppearanceFailure(description: "\(scenario): missing fixture rows") }
                clickRow(table, row: 0, x: 80)
                try await Task.sleep(for: .milliseconds(250))
                guard table.selectedRow == 0 else { throw AppearanceFailure(description: "\(scenario): detail was not selected") }
                try verifyContentBounds(window, context: "\(scenario)-\(name)-selected")
            }
        }
        // Resize the same live hierarchy while the watching page (and, if populated, its detail) is open.
        let originalSize = window.contentView!.bounds.size
        let otherSize = originalSize.width > 1000 ? NSSize(width: 880, height: 580) : NSSize(width: 1080, height: 700)
        for size in [otherSize, originalSize] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(250))
            try verifyContentBounds(window, context: "\(scenario)-resized-\(Int(size.width))")
        }
        print("Passed window layout: \(scenario); sidebar switching, details and live resizing.")
    }

    @MainActor private func verifyContentBounds(_ window: NSWindow, context: String) throws {
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        guard let split = nativeViews(in: content, as: NSSplitView.self).first,
              split.arrangedSubviews.count == 3,
              let field = nativeViews(in: split.arrangedSubviews[1], as: NSTextField.self).first(where: \.isEditable) else {
            throw AppearanceFailure(description: "\(context): missing three-column layout or search field")
        }
        let splitRect = split.convert(split.bounds, to: content)
        guard splitRect.minY >= content.bounds.minY - 1, splitRect.maxY <= content.bounds.maxY + 1 else {
            throw AppearanceFailure(description: "\(context): split view exceeds window bounds: \(splitRect), content: \(content.bounds)")
        }
        // A search field sits below the page title. Checking it against AppKit's actual
        // content layout rect catches headers pushed into the title bar after a route change.
        let fieldRect = field.convert(field.bounds, to: nil)
        let gap = window.contentLayoutRect.maxY - fieldRect.maxY
        guard gap >= 30, fieldRect.minY >= window.contentLayoutRect.minY else {
            throw AppearanceFailure(description: "\(context): search/header overlaps the title bar; gap=\(gap)")
        }
    }

    @MainActor private func verifyMonitorFlow(window: NSWindow, monitor: PriceMonitorStore, navigation: MonitorNavigation) async throws {
        let unread = monitor.unreadCount
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        precondition(monitor.unreadCount == unread, "Opening reminders must not automatically read the first event")
        let event = monitor.state.events.first { $0.kind == .inAppPurchase }!
        let initialSplit = nativeViews(in: window.contentView!, as: NSSplitView.self).first!
        guard let search = nativeViews(in: initialSplit.arrangedSubviews[1], as: NSTextField.self).first(where: \.isEditable) else {
            throw AppearanceFailure(description: "Reminder search field was not rendered")
        }
        window.makeFirstResponder(search)
        search.currentEditor()?.insertText("no-matching-offer")
        try await Task.sleep(for: .milliseconds(200))
        navigation.showReminders(event.id)
        try await Task.sleep(for: .milliseconds(350))
        precondition(monitor.unreadCount == unread - 1, "Menu deep link must read only the selected event")
        await monitor.markRead([event.id], read: false)
        try await Task.sleep(for: .milliseconds(150))
        precondition(monitor.unreadCount == unread, "Mark unread must remain unread while selected")
        guard let split = nativeViews(in: window.contentView!, as: NSSplitView.self).first,
              split.arrangedSubviews.count == 3,
              let table = nativeViews(in: split.arrangedSubviews[1], as: NSTableView.self).first,
              table.numberOfRows == monitor.state.events.count else {
            throw AppearanceFailure(description: "Menu route must clear old search filters and render all app and IAP offers")
        }
        window.orderOut(nil)
        print("Passed: reminders open without reading all offers; menu route reads only its target; explicit unread state remains stable.")
    }

    @MainActor private func verifyWatchEditor(window: NSWindow, monitor: PriceMonitorStore) async throws {
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard let split = nativeViews(in: window.contentView!, as: NSSplitView.self).first,
              let add = nativeViews(in: split.arrangedSubviews[1], as: NSButton.self)
                .max(by: { $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY }) else {
            throw AppearanceFailure(description: "Add watch button was not available")
        }
        add.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard let sheet = window.sheets.first,
              let field = nativeViews(in: sheet.contentView!, as: NSTextField.self).first(where: \.isEditable) else {
            throw AppearanceFailure(description: "Add watch sheet did not open")
        }
        sheet.makeFirstResponder(field)
        field.currentEditor()?.insertText("https://apps.apple.com/cn/app/id123456789")
        try await Task.sleep(for: .milliseconds(200))
        // SwiftUI identifiers live on drawing nodes, not necessarily the native NSButton.
        // The verification and save actions occupy the upper/lower trailing corners.
        func trailingControls() -> [NSButton] {
            nativeViews(in: sheet.contentView!, as: NSButton.self).filter {
                $0.convert($0.bounds, to: nil).midX > sheet.contentView!.bounds.width * 0.65
            }
        }
        func saveControl() -> NSButton? {
            trailingControls().min {
                let left = $0.convert($0.bounds, to: nil)
                let right = $1.convert($1.bounds, to: nil)
                return abs(left.midY - right.midY) < 2 ? left.midX > right.midX : left.midY < right.midY
            }
        }
        guard let lookup = trailingControls().max(by: { $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY }),
              let save = saveControl() else {
            throw AppearanceFailure(description: "Watch verification controls were not available")
        }
        precondition(!save.isEnabled, "Cannot save before verifying the app")
        lookup.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        let verifiedSave = saveControl()!
        precondition(verifiedSave.isEnabled, "Verified fixture should enable follow")
        verifiedSave.performClick(nil)
        try await Task.sleep(for: .milliseconds(300))
        guard window.sheets.isEmpty,
              let watch = monitor.state.watches.first(where: { $0.app.storeID == 123456789 }),
              watch.watchesApplication && watch.watchesPurchases else {
            throw AppearanceFailure(description: "Verified app was not saved with both watch scopes")
        }
        await monitor.remove(watchID: watch.id)
        window.orderOut(nil)
        print("Passed: native watch sheet verifies an app with an offline fixture, saves both scopes and dismisses.")
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

    @MainActor private func window<Content: View>(_ content: Content, size: NSSize, useHostingView: Bool = false, manager: Bool = false) -> NSWindow {
        // Match AppDelegate.openManager(), including the full-size title bar and unified toolbar.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: manager ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        if manager {
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
        }
        if useHostingView {
            window.contentView = NSHostingView(rootView: content)
        } else {
            window.contentViewController = NSHostingController(rootView: content)
        }
        if manager { window.titleVisibility = .hidden }
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
