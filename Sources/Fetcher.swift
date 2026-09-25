import Foundation
import AppKit

// MARK: - 数据模型

struct AppSuggestion: Codable, Hashable {
    let text: String
    let source: String      // "appstore" | "brew"
    let title: String
    let seller: String
    let score: Double
    let appStoreID: Int64?
}

final class SuggestionStore: ObservableObject {
    static let shared = SuggestionStore()

    @Published private(set) var suggestions: [String: AppSuggestion] = [:]
    @Published private(set) var ignored: Set<String> = []

    private let storeURL: URL

    private struct Storage: Codable {
        var suggestions: [String: AppSuggestion] = [:]
        var ignored: [String] = []
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("suggestions.json")
        load()
    }

    func raw(for path: String) -> AppSuggestion? { suggestions[path] }

    func suggestion(for path: String) -> AppSuggestion? {
        ignored.contains(path) ? nil : suggestions[path]
    }

    func set(_ suggestion: AppSuggestion, for path: String) {
        suggestions[path] = suggestion
        ignored.remove(path)
        save()
    }

    func ignore(_ path: String) {
        ignored.insert(path)
        save()
    }

    func unignore(_ path: String) {
        ignored.remove(path)
        save()
    }

    func remove(_ path: String) {
        suggestions.removeValue(forKey: path)
        save()
    }

    var count: Int { suggestions.count }

    /// 退出前强制落盘
    func flush() {
        let snapshot = Storage(suggestions: suggestions, ignored: Array(ignored))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let s = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        suggestions = s.suggestions
        ignored = Set(s.ignored)
    }

    private func save() {
        let snapshot = Storage(suggestions: suggestions, ignored: Array(ignored))
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: self.storeURL, options: .atomic)
        }
    }
}

final class FetchProgress: ObservableObject {
    static let shared = FetchProgress()

    @Published var isRunning = false
    @Published var current = 0
    @Published var total = 0
    @Published var currentName = ""
    @Published var found = 0
    @Published var cancelRequested = false
}

// MARK: - 抓取

private struct iTunesResult: Decodable {
    let trackId: Int64?
    let trackName: String?
    let description: String?
    let sellerName: String?
    let version: String?
}

private struct iTunesResponse: Decodable {
    let resultCount: Int
    let results: [iTunesResult]
}

final class DescriptionFetcher {
    static let shared = DescriptionFetcher()

    private let session = URLSession(configuration: .ephemeral)

    // MARK: 主流程

    func fetchAll(apps: [AppEntry], progress: FetchProgress) async {
        let canStart = await MainActor.run {
            guard !progress.isRunning, !apps.isEmpty else { return false }
            progress.isRunning = true
            progress.current = 0
            progress.total = apps.count
            progress.found = 0
            progress.currentName = ""
            progress.cancelRequested = false
            return true
        }
        guard canStart else { return }

        let brewMap = await brewDescriptions()

        for (index, app) in apps.enumerated() {
            if await isCancelled(progress) { break }

            // 每 3 个应用更新一次进度，避免 SwiftUI 被高频 re-render 卡死
            if index % 3 == 0 || index == apps.count - 1 {
                await update(progress) {
                    $0.current = index + 1
                    $0.currentName = app.name
                }
            }

            let store = SuggestionStore.shared
            let existing = store.raw(for: app.path)
            let canReuse = if let existing {
                (existing.source == "brew" && app.appStoreID == nil) ||
                    (existing.source == "appstore" && app.appStoreID != nil && existing.appStoreID == app.appStoreID)
            } else {
                false
            }
            if canReuse { continue }
            if existing != nil {
                await MainActor.run { store.remove(app.path) }
            }
            if store.ignored.contains(app.path) { continue }
            // 系统自带应用不可能在 Mac App Store 里，跳过可以避开大量同名误匹配
            if isSystemApp(app) { continue }

            var suggestion: AppSuggestion?
            if app.appStoreID != nil {
                suggestion = await lookupAppStore(app: app)
            } else if let desc = brewMap[app.fileName], !desc.isEmpty {
                suggestion = AppSuggestion(text: desc, source: "brew", title: app.name, seller: "Homebrew Cask", score: 1.0, appStoreID: nil)
            }

            if let suggestion {
                await MainActor.run {
                    SuggestionStore.shared.set(suggestion, for: app.path)
                    progress.found += 1
                }
            }

            // 节流：Apple lookup API 有速率限制
            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        await MainActor.run { progress.isRunning = false }
    }

    // MARK: App Store

    private func lookupAppStore(app: AppEntry) async -> AppSuggestion? {
        guard let appStoreID = app.appStoreID else { return nil }
        var countries = [app.storefrontCountryCode, "cn", "us"]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        countries = countries.reduce(into: [String]()) { result, country in
            if !result.contains(country) { result.append(country) }
        }

        for country in countries {
            guard let hit = await lookupAppStore(id: appStoreID, country: country),
                  let raw = hit.description, !raw.isEmpty else { continue }

            let text = summarize(raw)
            guard !text.isEmpty else { continue }

            return AppSuggestion(
                text: text,
                source: "appstore",
                title: hit.trackName ?? app.name,
                seller: hit.sellerName ?? "",
                score: 1.0,
                appStoreID: appStoreID
            )
        }
        return nil
    }

    private func lookupAppStore(id: Int64, country: String) async -> iTunesResult? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = components.url,
              let data = await appStoreData(from: url),
              let decoded = try? JSONDecoder().decode(iTunesResponse.self, from: data) else { return nil }
        return decoded.results.first(where: { $0.trackId == id })
    }

    private func appStoreData(from url: URL) async -> Data? {
        for attempt in 0..<2 {
            do {
                let (data, response) = try await AppleRequestQueue.shared.data(from: url, session: session)
                if let http = response as? HTTPURLResponse, http.statusCode == 403 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                return data
            } catch {
                if attempt == 1 { return nil }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        return nil
    }

    // MARK: Homebrew 兜底

    private func brewDescriptions() async -> [String: String] {
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let brew else { return [:] }

        guard let tokens = run(brew, ["list", "--cask"])?
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty }), !tokens.isEmpty else { return [:] }

        guard let output = run(brew, ["info", "--cask", "--json=v2"] + tokens),
              let jsonStart = output.firstIndex(of: "{"),
              let data = output[jsonStart...].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = object["casks"] as? [[String: Any]] else { return [:] }

        var map: [String: String] = [:]
        for cask in casks {
            guard let desc = cask["desc"] as? String, !desc.isEmpty else { continue }
            var names: [String] = []
            if let artifacts = cask["artifacts"] as? [[String: Any]] {
                for artifact in artifacts {
                    if let apps = artifact["app"] as? [String] { names.append(contentsOf: apps) }
                }
            }
            if let display = cask["name"] as? [String] {
                names.append(contentsOf: display.map { $0 + ".app" })
            }
            for name in names { map[name] = desc }
        }
        return map
    }

    private func run(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: 工具

    private func isSystemApp(_ app: AppEntry) -> Bool {
        if app.path.hasPrefix("/System/") { return true }
        if let bundleID = app.bundleID {
            if bundleID.hasPrefix("com.apple.") { return true }
            if bundleID == Bundle.main.bundleIdentifier { return true }
        }
        return false
    }

    private func update(_ progress: FetchProgress, _ body: @escaping (FetchProgress) -> Void) async {
        await MainActor.run { body(progress) }
    }

    private func isCancelled(_ progress: FetchProgress) async -> Bool {
        await MainActor.run { progress.cancelRequested }
    }

    /// 取第一段作为摘要，太短就并上第二段，最后截断
    private func summarize(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var result = lines.first else { return "" }
        if result.count < 24, lines.count > 1 { result += " " + lines[1] }
        if result.count > 140 { result = String(result.prefix(140)) + "…" }
        return result
    }
}
