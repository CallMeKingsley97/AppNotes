import Foundation
import AppKit

struct AppEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let bundleID: String?
    let version: String?
    let appStoreID: Int64?
    let storefrontCountryCode: String?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
}

enum AppCategory: String, CaseIterable, Identifiable {
    case system
    case appStore
    case downloaded

    var id: Self { self }

    static func of(_ app: AppEntry) -> AppCategory {
        if app.path.hasPrefix("/System/") {
            return .system
        }
        if app.appStoreID != nil { return .appStore }
        return app.bundleID?.hasPrefix("com.apple.") == true ? .system : .downloaded
    }

    var titleKey: String { "category.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .system: return "apple.logo"
        case .appStore: return "bag"
        case .downloaded: return "arrow.down.circle"
        }
    }
}

// A shared scan keeps the manager, menu actions, and quick search in sync.
final class AppLibrary: ObservableObject {
    static let shared = AppLibrary()
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var isScanning = false
    private var hasScanned = false

    init(apps: [AppEntry]? = nil) {
        self.apps = apps ?? []
        hasScanned = apps != nil
    }

    func scanIfNeeded() {
        if !hasScanned { refresh() }
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = AppScanner.scan()
            DispatchQueue.main.async {
                self.apps = scanned
                self.isScanning = false
                self.hasScanned = true
            }
        }
    }
}

enum AppScanner {
    static func scan() -> [AppEntry] {
        let fm = FileManager.default
        let home = NSHomeDirectory() as NSString
        let dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            home.appendingPathComponent("Applications"),
            home.appendingPathComponent("Applications/Chrome Apps"),
            home.appendingPathComponent("Applications (Parallels)"),
        ]

        var seen = Set<String>()
        var result: [AppEntry] = []

        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(item)
                if seen.contains(path) { continue }
                if isInsideAppBundle(path) { continue }
                seen.insert(path)

                let bundle = Bundle(path: path)
                let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                let bundleName = (displayName?.isEmpty == false ? displayName : nil)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                let fileName = (item as NSString).deletingPathExtension
                // CFBundleDisplayName 经常被写成空串 "" 而不是不写，
                // ?? 不会跳过空串，所以要把空串也当没找到处理
                let name = (bundleName?.isEmpty == false ? bundleName : nil)
                    ?? (fileName.isEmpty ? "App" : fileName)
                let storeMetadata = appStoreMetadata(at: path)

                result.append(
                    AppEntry(
                        path: path,
                        name: name,
                        bundleID: bundle?.bundleIdentifier,
                        version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                        appStoreID: storeMetadata.id,
                        storefrontCountryCode: storeMetadata.storefrontCountryCode
                    ))
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func appStoreMetadata(at path: String) -> (id: Int64?, storefrontCountryCode: String?) {
        let attributeName = "com.apple.appstore.metadata"
        var data = Data()
        let readSize = path.withCString { pathPointer in
            attributeName.withCString { namePointer in
                let size = getxattr(pathPointer, namePointer, nil, 0, 0, 0)
                guard size > 0 else { return -1 }
                data = Data(count: size)
                return data.withUnsafeMutableBytes { buffer in
                    getxattr(pathPointer, namePointer, buffer.baseAddress, buffer.count, 0, 0)
                }
            }
        }
        guard readSize > 0 else { return (id: nil, storefrontCountryCode: nil) }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else { return (id: nil, storefrontCountryCode: nil) }

        let metadata = (plist["iTunesMetadata"] as? [String: Any]) ?? plist
        return (
            id: (metadata["itemId"] as? NSNumber)?.int64Value,
            storefrontCountryCode: metadata["storefrontCountryCode"] as? String
        )
    }

    private static func isInsideAppBundle(_ path: String) -> Bool {
        var current = (path as NSString).deletingLastPathComponent
        while current != "/" && !current.isEmpty {
            if current.hasSuffix(".app") { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }
}

final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [String: String] = [:]

    private let storeURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = base.appendingPathComponent("notes.json")
        load()
    }

    func note(for path: String) -> String {
        notes[path] ?? ""
    }

    func set(_ text: String, for path: String) {
        let trimmed = text
        if trimmed.isEmpty {
            notes.removeValue(forKey: path)
        } else {
            notes[path] = trimmed
        }
        scheduleSave()
    }

    var count: Int { notes.count }

    /// 退出前强制落盘，避免延迟写入丢数据
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let snapshot = notes
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        notes = dict
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = notes
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: self.storeURL, options: .atomic)
        }
        saveWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 64, height: 64)
        cache[path] = img
        return img
    }
}
