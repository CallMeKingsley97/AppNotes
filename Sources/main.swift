import Cocoa
import SwiftUI
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var managerWindow: NSWindow?
    private var searchPanel: FloatingPanel?
    private var hudPanel: NSPanel?
    private var hudTimer: Timer?
    private var cachedApps: [AppEntry] = []
    private var hudMenuItem = NSMenuItem()

    private var hudEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "hudEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "hudEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupKeyMonitor()
        registerHotkey()
        observeAppSwitch()
        refreshApps()

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
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "AppNotes")
            button.toolTip = "AppNotes · 应用备注"
        }

        let menu = NSMenu()
        let managerItem = NSMenuItem(title: "管理备注…", action: #selector(openManager), keyEquivalent: "")
        let searchItem = NSMenuItem(title: "搜索备注   ⌃⌥N", action: #selector(showSearchAction), keyEquivalent: "")
        hudMenuItem = NSMenuItem(title: "切换 App 时显示备注", action: #selector(toggleHUD), keyEquivalent: "")
        hudMenuItem.state = hudEnabled ? .on : .off
        let rescanItem = NSMenuItem(title: "重新扫描应用", action: #selector(rescan), keyEquivalent: "")
        let fetchItem = NSMenuItem(title: "抓取 Mac App Store 简介…", action: #selector(fetchDescriptions), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")

        for item in [managerItem, searchItem, rescanItem, fetchItem, hudMenuItem, quitItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.insertItem(NSMenuItem.separator(), at: 4)
        statusItem.menu = menu
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

    private func refreshApps() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = AppScanner.scan()
            DispatchQueue.main.async { self?.cachedApps = scanned }
        }
    }

    // MARK: - Actions

    @objc private func rescan() {
        refreshApps()
    }

    @objc private func fetchDescriptions() {
        let apps = cachedApps
        Task { await DescriptionFetcher.shared.fetchAll(apps: apps, progress: FetchProgress.shared) }
    }

    @objc private func openManager() {
        if managerWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "应用备注"
            window.titleVisibility = .visible
            window.contentViewController = NSHostingController(rootView: ManagerView())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            managerWindow = window
        }
        managerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSearchAction() {
        showSearch()
    }

    private func showSearch() {
        if searchPanel != nil {
            searchPanel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let apps = cachedApps.isEmpty ? AppScanner.scan() : cachedApps
        let panel = FloatingPanel()
        let root = SearchOverlayView(apps: apps) { [weak self] in
            self?.searchPanel?.close()
            self?.searchPanel = nil
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.delegate = self
        searchPanel = panel

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let size = panel.frame.size
            let x = sf.midX - size.width / 2
            let y = sf.midY + sf.height * 0.25 - size.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleHUD() {
        hudEnabled.toggle()
        hudMenuItem.state = hudEnabled ? .on : .off
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
        guard hudEnabled else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        var note = ""
        if let path = app.bundleURL?.path {
            note = NotesStore.shared.note(for: path)
        }
        if note.isEmpty, let bundleID = app.bundleIdentifier,
           let match = cachedApps.first(where: { $0.bundleID == bundleID }) {
            note = NotesStore.shared.note(for: match.path)
        }
        guard !note.isEmpty else { return }

        let name = app.localizedName ?? (app.bundleURL?.lastPathComponent as NSString?)?.deletingPathExtension ?? ""
        showHUD(appName: name, note: note)
    }

    private func showHUD(appName: String, note: String) {
        hudTimer?.invalidate()
        hudPanel?.orderOut(nil)

        let hosting = NSHostingView(rootView: HUDView(appName: appName, note: note))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let sf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: sf.midX - size.width / 2, y: sf.maxY - size.height - 28))
        panel.orderFrontRegardless()
        hudPanel = panel

        hudTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    self?.hudPanel?.animator().alphaValue = 0
                } completionHandler: {
                    self?.hudPanel?.orderOut(nil)
                    self?.hudPanel = nil
                }
            }
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
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === searchPanel {
            window.close()
            searchPanel = nil
        }
    }
}

final class FloatingPanel: NSPanel {
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
        close()
    }
}

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()
