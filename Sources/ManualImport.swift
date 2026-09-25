import Foundation
import AppKit

struct AppStoreLink: Equatable, Sendable {
    let trackID: Int64
    let countryCode: String?

    static func parse(_ text: String) -> AppStoreLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = url(from: trimmed), let link = parse(url: url) { return link }
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:https?|itms-apps|itms|macappstore)://[^\s<>"'，。、]+"#
        ) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in expression.matches(in: trimmed, options: [], range: range) {
            guard let matchRange = Range(match.range, in: trimmed) else { continue }
            var raw = String(trimmed[matchRange])
            while let last = raw.last, ".,);".contains(last) { raw.removeLast() }
            if let url = url(from: raw), let link = parse(url: url) { return link }
        }
        return nil
    }

    private static func url(from raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil, url.host != nil { return url }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded), url.host != nil else { return nil }
        return url
    }

    private static let storeHosts: Set<String> = [
        "apps.apple.com", "itunes.apple.com", "geo.itunes.apple.com"
    ]

    private static func parse(url: URL) -> AppStoreLink? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "itms", "itms-apps", "macappstore"].contains(scheme),
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard storeHosts.contains(host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let appIndex = parts.firstIndex(of: "app"),
              let idPart = parts[appIndex...].last(where: isProductID),
              let trackID = Int64(idPart.dropFirst(2)) else { return nil }
        let country = parts.first.flatMap { code -> String? in
            guard code.count == 2, code.allSatisfy(\.isLetter) else { return nil }
            return code.lowercased()
        }
        return AppStoreLink(trackID: trackID, countryCode: country)
    }

    private static func isProductID(_ part: String) -> Bool {
        guard part.hasPrefix("id"), let value = Int64(part.dropFirst(2)), value > 0 else { return false }
        return String(value) == String(part.dropFirst(2))
    }
}

struct ManualImportRecord: Codable, Equatable, Identifiable, Sendable {
    let appStoreID: Int64
    var name: String
    var bundleID: String?
    var version: String?
    var seller: String?
    var storefrontCountryCode: String?
    var artworkURL: String?

    var id: Int64 { appStoreID }

    var entry: AppEntry {
        AppEntry(
            path: Self.path(for: appStoreID),
            name: name,
            bundleID: bundleID,
            version: version,
            appStoreID: appStoreID,
            storefrontCountryCode: storefrontCountryCode,
            origin: .manual,
            artworkURL: artworkURL
        )
    }

    static func path(for appStoreID: Int64) -> String { "appnotes-import/\(appStoreID)" }
}

final class ManualImportStore: ObservableObject {
    static let shared = ManualImportStore()
    @Published private(set) var records: [ManualImportRecord] = []
    @Published var focusPath: String?
    @Published var errorKey: String?

    private struct Storage: Codable { var imports: [ManualImportRecord] }
    private let storeURL: URL
    private var loadFailed = false

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("manual-imports.json")
        load()
    }

    var entries: [AppEntry] { records.map(\.entry) }

    func contains(_ appStoreID: Int64) -> Bool { records.contains { $0.appStoreID == appStoreID } }

    @discardableResult
    func add(_ record: ManualImportRecord) -> Bool {
        var updated = records.filter { $0.appStoreID != record.appStoreID }
        updated.append(record)
        return save(updated)
    }

    @discardableResult
    func remove(_ appStoreID: Int64) -> Bool {
        let path = ManualImportRecord.path(for: appStoreID)
        if focusPath == path { focusPath = nil }
        return save(records.filter { $0.appStoreID != appStoreID })
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let storage = try JSONDecoder().decode(Storage.self, from: Data(contentsOf: storeURL))
            records = storage.imports
        } catch {
            loadFailed = true
            errorKey = "import.loadFailed"
        }
    }

    private func save(_ records: [ManualImportRecord]) -> Bool {
        guard !loadFailed else { errorKey = "import.loadFailed"; return false }
        do {
            let data = try JSONEncoder().encode(Storage(imports: records))
            try data.write(to: storeURL, options: .atomic)
            self.records = records
            errorKey = nil
            return true
        } catch {
            errorKey = "import.saveFailed"
            return false
        }
    }
}

enum ClipboardImport {
    enum Outcome: Equatable {
        case ignore
        case prompt(ManualImportRecord)
        case failed
    }

    static func resolve(
        clipboard: String,
        existing: [AppEntry],
        lookup: (AppStoreLink) async throws -> ManualImportRecord?
    ) async -> Outcome {
        guard let link = AppStoreLink.parse(clipboard) else { return .ignore }
        if existing.contains(where: { $0.appStoreID == link.trackID }) { return .ignore }
        do {
            guard let record = try await lookup(link) else { return .failed }
            if existing.contains(where: { $0.appStoreID == record.appStoreID }) { return .ignore }
            if let bundle = record.bundleID,
               existing.contains(where: { $0.origin != .manual && $0.bundleID == bundle }) {
                return .ignore
            }
            return .prompt(record)
        } catch {
            return .failed
        }
    }
}

struct AppStoreLinkLookup {
    var session: URLSession = AppStoreLinkLookup.makeSession()
    var preferredLanguages: [String] = Locale.preferredLanguages

    func record(for link: AppStoreLink) async throws -> ManualImportRecord? {
        var countries: [String] = []
        if let country = link.countryCode { countries.append(country) }
        countries.append(preferredLanguages.first?.hasPrefix("zh") == true ? "cn" : "us")
        countries.append(contentsOf: ["cn", "us"])
        var seen = Set<String>()
        for country in countries where seen.insert(country).inserted {
            if let record = try await fetch(id: link.trackID, country: country) { return record }
        }
        return nil
    }

    static func record(from data: Data, country: String, trackID: Int64) -> ManualImportRecord? {
        struct Response: Decodable {
            struct Item: Decodable {
                let trackId: Int64?
                let trackName: String?
                let bundleId: String?
                let sellerName: String?
                let artistName: String?
                let version: String?
                let artworkUrl512: String?
                let artworkUrl100: String?
                let wrapperType: String?
                let kind: String?
            }
            let results: [Item]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let matches = decoded.results.filter { item in
            (item.trackId == nil || item.trackId == trackID)
                && (item.wrapperType == nil || item.wrapperType == "software")
        }
        guard let item = matches.first(where: { $0.kind == "mac-software" }) ?? matches.first,
              let name = item.trackName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let seller = (item.sellerName?.isEmpty == false ? item.sellerName : nil) ?? item.artistName
        return ManualImportRecord(
            appStoreID: trackID,
            name: name,
            bundleID: item.bundleId?.isEmpty == false ? item.bundleId : nil,
            version: item.version?.isEmpty == false ? item.version : nil,
            seller: seller?.isEmpty == false ? seller : nil,
            storefrontCountryCode: country,
            artworkURL: item.artworkUrl512 ?? item.artworkUrl100
        )
    }

    private func fetch(id: Int64, country: String) async throws -> ManualImportRecord? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "lang", value: country == "cn" ? "zh_cn" : "en_us"),
        ]
        guard let url = components.url else { return nil }
        let (data, response) = try await AppleRequestQueue.shared.data(from: url, session: session)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return Self.record(from: data, country: country, trackID: id)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "AppNotes/1.0 (macOS; App information)"]
        return URLSession(configuration: configuration)
    }
}

final class ClipboardImportMonitor {
    var onImported: () -> Void = {}
    private let lookup = AppStoreLinkLookup()
    private let handledKey = "clipboardImport.changeCount"
    private var evaluation: Task<Void, Never>?

    /// Remember the pasteboard generation across launches so a declined link is not asked again until it is copied again.
    private var handledChangeCount: Int? {
        get {
            guard UserDefaults.standard.object(forKey: handledKey) != nil else { return nil }
            return UserDefaults.standard.integer(forKey: handledKey)
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: handledKey) }
        }
    }

    func consider() {
        guard evaluation == nil else { return }
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        guard handledChangeCount != change else { return }
        guard let text = clipboardLink(on: pasteboard) else {
            // An empty or unrelated clipboard should not be asked about again until it changes.
            handledChangeCount = change
            return
        }
        evaluation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.evaluation = nil
                if NSPasteboard.general.changeCount != change { self.consider() }
            }
            while AppLibrary.shared.isScanning {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, NSPasteboard.general.changeCount == change else { return }
            let outcome = await ClipboardImport.resolve(
                clipboard: text,
                existing: AppLibrary.shared.apps,
                lookup: { try await self.lookup.record(for: $0) }
            )
            guard !Task.isCancelled, NSPasteboard.general.changeCount == change, NSApp.isActive else { return }
            switch outcome {
            case .ignore:
                self.handledChangeCount = change
            case .failed:
                self.handledChangeCount = change
                self.present(titleKey: "import.failed.title", messageKey: "import.failed.message", confirms: false)
            case .prompt(let record):
                guard self.present(record: record) else {
                    self.handledChangeCount = change
                    return
                }
                self.handledChangeCount = change
                guard ManualImportStore.shared.add(record) else {
                    self.present(titleKey: "import.failed.title", messageKey: "import.saveFailed", confirms: false)
                    return
                }
                AppLibrary.shared.reloadImports()
                ManualImportStore.shared.focusPath = record.entry.path
                self.onImported()
            }
        }
    }

    private func present(record: ManualImportRecord) -> Bool {
        let preferences = AppPreferences.shared
        var message = preferences.text("import.prompt.message", record.name)
        if let seller = record.seller, !seller.isEmpty { message += "\n" + seller }
        return present(title: preferences.text("import.prompt.title"), message: message, confirms: true)
    }

    private func present(titleKey: String, messageKey: String, confirms: Bool) {
        let preferences = AppPreferences.shared
        _ = present(title: preferences.text(titleKey), message: preferences.text(messageKey), confirms: confirms)
    }

    private func present(title: String, message: String, confirms: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = confirms ? .informational : .warning
        let preferences = AppPreferences.shared
        if confirms {
            alert.addButton(withTitle: preferences.text("import.confirm"))
            alert.addButton(withTitle: preferences.text("import.cancel"))
            alert.buttons[1].keyEquivalent = "\u{1b}"
        } else {
            alert.addButton(withTitle: preferences.text("info.ok"))
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func clipboardLink(on pasteboard: NSPasteboard) -> String? {
        var candidates: [String] = []
        if let string = pasteboard.string(forType: .string) { candidates.append(string) }
        if let url = pasteboard.string(forType: .URL) { candidates.append(url) }
        for item in pasteboard.pasteboardItems ?? [] {
            if let string = item.string(forType: .string) { candidates.append(string) }
            if let url = item.string(forType: .URL) { candidates.append(url) }
        }
        return candidates.first { AppStoreLink.parse($0) != nil }
    }
}
