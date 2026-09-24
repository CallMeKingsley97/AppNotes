import Cocoa
import SwiftUI
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var managerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var searchPanel: FloatingPanel?
    private let searchPresence = PanelPresence()
    private var searchGeneration = 0
    private var searchHiding = false
    private var hudPanel: NSPanel?
    private var hudHosting: NSHostingView<AppRoot<HUDView>>?
    private let hudContent = HUDContent(presented: false)
    private var hudTimer: Timer?
    private var hudGeneration = 0
    private let preferences = AppPreferences.shared
    private let library = AppLibrary.shared
    private var hudMenuItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = preferences.appearance.nativeAppearance
        setupStatusItem()
        setupApplicationMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: AppPreferences.didChange, object: preferences)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        setupKeyMonitor()
        registerHotkey()
        observeAppSwitch()
        library.refresh()

        if !UserDefaults.standard.bool(forKey: "didOpenManagerOnce") {
            UserDefaults.standard.set(true, forKey: "didOpenManagerOnce")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openManager()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotesStore.shared.flush()
        SuggestionStore.shared.flush()
        AppDetailsStore.shared.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visibleWindows: Bool) -> Bool {
        guard !visibleWindows else {
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        openManager()
        return true
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "AppNotes")
            button.toolTip = "AppNotes · " + preferences.text("app.title")
        }

        let menu = NSMenu()
        menu.addItem(menuItem("menu.manager", action: #selector(openManager)))
        let searchItem = menuItem("menu.search", action: #selector(showSearchAction), key: "n")
        searchItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(searchItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("library.scan", action: #selector(rescan)))
        menu.addItem(menuItem("menu.fetch", action: #selector(fetchDescriptions)))
        hudMenuItem = menuItem("settings.hud", action: #selector(toggleHUD))
        hudMenuItem.state = preferences.hudEnabled ? .on : .off
        menu.addItem(hudMenuItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("settings.open", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("menu.quit", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func menuItem(_ key: String, action: Selector, key equivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: preferences.text(key), action: action, keyEquivalent: equivalent)
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(rescan): return !library.isScanning
        case #selector(fetchDescriptions):
            return !library.isScanning && !library.apps.isEmpty && !FetchProgress.shared.isRunning
        default: return true
        }
    }

    // AppKit's responder chain gives the note editor standard copy/paste and undo shortcuts.
    private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "AppNotes")
        appMenu.addItem(menuItem("settings.open", action: #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: preferences.text("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)
        appMenu.addItem(menuItem("menu.quit", action: #selector(quit), key: "q"))
        let appItem = NSMenuItem(title: "AppNotes", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: preferences.text("menu.edit"))
        let editActions: [(String, String, String)] = [
            ("menu.undo", "undo:", "z"), ("menu.redo", "redo:", "Z"),
            ("menu.cut", "cut:", "x"), ("menu.copy", "copy:", "c"),
            ("menu.paste", "paste:", "v"), ("menu.selectAll", "selectAll:", "a")
        ]
        for (index, entry) in editActions.enumerated() {
            if index == 2 { editMenu.addItem(.separator()) }
            editMenu.addItem(NSMenuItem(title: preferences.text(entry.0),
                                        action: NSSelectorFromString(entry.1), keyEquivalent: entry.2))
        }
        let editItem = NSMenuItem(title: editMenu.title, action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let windowMenu = NSMenu(title: preferences.text("menu.window"))
        windowMenu.addItem(NSMenuItem(title: preferences.text("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: preferences.text("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem(title: windowMenu.title, action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func preferencesChanged() {
        NSApp.appearance = preferences.appearance.nativeAppearance
        // Windows and hosting views inherit the app appearance, including live system changes.
        managerWindow?.title = preferences.text("app.title")
        settingsWindow?.title = preferences.text("settings.title")
        setupStatusItem()
        setupApplicationMenu()
        if !preferences.hudEnabled {
            hudTimer?.invalidate()
            hudPanel?.orderOut(nil)
            hudPanel = nil
        }
        preferences.objectWillChange.send()
    }

    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
                NSApp.keyWindow?.close()
                return nil
            }
            return event
        }
    }

    // MARK: - Actions

    @objc private func rescan() {
        library.refresh()
    }

    @objc private func fetchDescriptions() {
        let apps = library.apps
        Task { await DescriptionFetcher.shared.fetchAll(apps: apps, progress: FetchProgress.shared) }
    }

    @objc private func openManager() {
        if managerWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = preferences.text("app.title")
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.contentViewController = NSHostingController(rootView: AppRoot {
                ManagerView(onSettings: { [weak self] in self?.openSettings() },
                            onSearch: { [weak self] in self?.showSearch() })
            })
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 1080, height: 700))
            window.setFrameAutosaveName("AppNotes.manager")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            managerWindow = window
        }
        managerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = preferences.text("settings.title")
            window.titlebarAppearsTransparent = true
            window.contentViewController = NSHostingController(rootView: AppRoot { SettingsView() })
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSearchAction() {
        showSearch()
    }

    private func showSearch() {
        let panel = ensureSearchPanel()
        searchHiding = false
        searchGeneration += 1
        let generation = searchGeneration
        searchPresence.session += 1
        let appearing = !panel.isVisible || panel.alphaValue < 0.99
        guard appearing else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        panel.ignoresMouseEvents = false
        if !panel.isVisible {
            searchPresence.shown = false
            panel.alphaValue = 0
            placeSearchPanel(panel)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.searchGeneration else { return }
            self.searchPresence.shown = true
            self.animate(panel, to: 1)
        }
    }

    private func ensureSearchPanel() -> FloatingPanel {
        if let searchPanel { return searchPanel }
        let panel = FloatingPanel()
        panel.onCancel = { [weak self] in self?.dismissSearch() }
        let presence = searchPresence
        let hosting = NSHostingView(rootView: AppRoot {
            SearchPanelRoot(presence: presence) { [weak self] in
                self?.dismissSearch()
            }
        })
        let size = NSSize(width: 580, height: 430)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.alphaValue = 0
        panel.delegate = self
        searchPanel = panel
        return panel
    }

    private func placeSearchPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first else { return }
        let sf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: sf.midX - size.width / 2, y: sf.midY + sf.height * 0.25 - size.height / 2))
    }

    private func dismissSearch() {
        guard let panel = searchPanel, panel.isVisible, !searchHiding else { return }
        searchHiding = true
        searchGeneration += 1
        let generation = searchGeneration
        searchPresence.shown = false
        panel.ignoresMouseEvents = true
        panel.resignKey()
        animate(panel, to: 0) { [weak self] in
            guard let self, generation == self.searchGeneration else { return }
            panel.orderOut(nil)
            panel.alphaValue = 0
            panel.ignoresMouseEvents = false
            self.searchHiding = false
        }
    }

    private func animate(_ panel: NSPanel, to alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.panelSeconds
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = alpha
        } completionHandler: {
            completion?()
        }
    }

    @objc private func toggleHUD() {
        preferences.hudEnabled.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.showSearch()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F5445), id: 1)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
    }

    // MARK: - HUD

    private func observeAppSwitch() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard preferences.hudEnabled else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        var note = ""
        if let path = app.bundleURL?.path {
            note = NotesStore.shared.note(for: path)
        }
        if note.isEmpty, let bundleID = app.bundleIdentifier,
           let match = library.apps.first(where: { $0.bundleID == bundleID }) {
            note = NotesStore.shared.note(for: match.path)
        }
        guard !note.isEmpty else { return }

        let name = app.localizedName ?? (app.bundleURL?.lastPathComponent as NSString?)?.deletingPathExtension ?? ""
        showHUD(appName: name, note: note, appPath: app.bundleURL?.path)
    }

    private func showHUD(appName: String, note: String, appPath: String?) {
        let panel = ensureHUDPanel()
        hudTimer?.invalidate()
        hudGeneration += 1
        let generation = hudGeneration
        hudContent.appName = appName
        hudContent.note = note
        hudContent.appPath = appPath
        resizeHUD()

        let appearing = !panel.isVisible || panel.alphaValue < 0.99
        if appearing {
            if !panel.isVisible {
                hudContent.presented = false
                panel.alphaValue = 0
            }
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.hudGeneration else { return }
                self.resizeHUD()
                self.hudContent.presented = true
                self.animate(panel, to: 1)
            }
        } else {
            hudContent.presented = true
            DispatchQueue.main.async { [weak self] in self?.resizeHUD() }
        }

        hudTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.dismissHUD(generation: generation)
        }
    }

    private func ensureHUDPanel() -> NSPanel {
        if let hudPanel { return hudPanel }
        let content = hudContent
        let hosting = NSHostingView(rootView: AppRoot { HUDView(content: content) })
        hosting.frame = NSRect(x: 0, y: 0, width: 390, height: 120)
        let panel = NSPanel(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.alphaValue = 0
        hudHosting = hosting
        hudPanel = panel
        return panel
    }

    private func resizeHUD() {
        guard let panel = hudPanel, let hosting = hudHosting else { return }
        hosting.frame.size.width = 390
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 300 { size.width = 390 }
        if size.height < 40 { size.height = 88 }
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let sf = screen.visibleFrame
        let origin = NSPoint(x: sf.midX - size.width / 2, y: sf.maxY - size.height - 28)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        hosting.frame = NSRect(origin: .zero, size: size)
    }

    private func dismissHUD(generation: Int) {
        guard generation == hudGeneration, let panel = hudPanel else { return }
        hudContent.presented = false
        animate(panel, to: 0) { [weak self] in
            guard let self, generation == self.hudGeneration else { return }
            panel.orderOut(nil)
            panel.alphaValue = 0
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === managerWindow {
            managerWindow = nil
        }
        if let window = notification.object as? NSWindow, window === searchPanel {
            searchPanel = nil
        }
        if let window = notification.object as? NSWindow, window === settingsWindow {
            settingsWindow = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === searchPanel {
            dismissSearch()
        }
    }
}

final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            close()
        }
    }
}

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()
