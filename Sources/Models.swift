import Foundation
import AppKit

struct AppEntry: Identifiable, Hashable {
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
        if app.path.hasPrefix("/System/") || app.bundleID?.hasPrefix("com.apple.") == true {
            return .system
        }
        return app.appStoreID != nil ? .appStore : .downloaded
    }

    var title: String {
        switch self {
        case .system: return "系统自带"
        case .appStore: return "App Store 下载"
        case .downloaded: return "网络下载"
        }
    }

    var tabTitle: String {
        switch self {
        case .system: return "系统"
        case .appStore: return "商店"
        case .downloaded: return "网络"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "gearshape.fill"
        case .appStore: return "cart.fill"
        case .downloaded: return "network"
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
                    ?? (fileName.isEmpty ? "未知应用" : fileName)
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

    init() {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/AppNotes")
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        self.storeURL = URL(fileURLWithPath: (base as NSString).appendingPathComponent("notes.json"))
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
