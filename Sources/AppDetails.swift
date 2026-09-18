import Foundation
import AppKit

struct StoreListing: Codable, Equatable, Sendable {
    let trackId: Int64
    let bundleId: String?
    let trackName: String?
    let kind: String?
    let description: String?
    let sellerName: String?
    let artistName: String?
    let artistViewUrl: String?
    let sellerUrl: String?
    let version: String?
    let price: Double?
    let currency: String?
    let formattedPrice: String?
    let averageUserRating: Double?
    let userRatingCount: Int?
    let genres: [String]?
    let contentAdvisoryRating: String?
    let languageCodesISO2A: [String]?
    let fileSizeBytes: String?
    let minimumOsVersion: String?
    let currentVersionReleaseDate: String?

    func storeURL(country: String, language: String) -> URL {
        var url = URLComponents(string: "https://apps.apple.com/\(country)/app/id\(trackId)")!
        url.queryItems = [URLQueryItem(name: "l", value: language == "zh-Hans" ? "zh-Hans-CN" : "en-US")]
        // Mac product links need the platform hint to avoid the iPhone storefront landing page.
        if kind == "mac-software" { url.queryItems?.append(URLQueryItem(name: "platform", value: "mac")) }
        return url.url!
    }

    func matches(_ app: AppEntry) -> Bool {
        if let bundleID = app.bundleID, bundleId != bundleID { return false }
        if let appStoreID = app.appStoreID { return trackId == appStoreID }
        // Bundle-only lookups must identify the Mac edition, never a similarly named iOS app.
        return kind == "mac-software" && app.bundleID != nil && bundleId == app.bundleID
    }
}

struct InAppPurchase: Codable, Equatable, Sendable {
    let name: String
    let price: String
}

struct AppRequirement: Codable, Equatable, Sendable {
    let platform: String
    let text: String
}

struct StorePageDetails: Codable, Equatable, Sendable {
    let purchases: [InAppPurchase]
    let hasInAppPurchases: Bool?
    let requirements: [AppRequirement]
    let releaseNotes: [AppReleaseNote]?

    // Only read the requested product's information shelf, not recommendations or marketing text.
    static func parse(_ html: String, listing: StoreListing, country: String) throws -> StorePageDetails {
        let expression = try NSRegularExpression(
            pattern: #"<script\b[^>]*\bid\s*=\s*["']serialized-server-data["'][^>]*>([\s\S]*?)</script>"#,
            options: .caseInsensitive)
        guard let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let data = String(html[range]).data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = root["data"] as? [[String: Any]],
              let page = pages.first(where: {
                  let intent = $0["intent"] as? [String: Any]
                  return String(describing: intent?["id"] ?? "") == String(listing.trackId)
                      && intent?["storefront"] as? String == country
              })?["data"] as? [String: Any],
              let lockup = page["lockup"] as? [String: Any],
              String(describing: lockup["adamId"] ?? "") == String(listing.trackId),
              listing.bundleId == nil || lockup["bundleId"] as? String == listing.bundleId,
              let shelves = page["shelfMapping"] as? [String: Any],
              let information = shelves["information"] as? [String: Any],
              let items = information["items"] as? [[String: Any]] else {
            throw AppDetailsError.invalidPage
        }
        let offer = page["titleOfferDisplayProperties"] as? [String: Any]
        var purchases: [InAppPurchase] = []
        var requirements: [AppRequirement] = []
        for item in items {
            let title = (item["title"] as? String ?? "").lowercased()
                .filter { !$0.isWhitespace }
            let children = item["items"] as? [[String: Any]] ?? []
            if ["app内购买", "in-apppurchases"].contains(title) {
                for child in children {
                    for pair in child["textPairs"] as? [[String]] ?? [] where pair.count == 2 {
                        if !pair[0].isEmpty && !pair[1].isEmpty {
                            purchases.append(InAppPurchase(name: pair[0], price: pair[1]))
                        }
                    }
                }
            } else if ["兼容性", "compatibility"].contains(title) {
                for child in children {
                    if let text = child["text"] as? String, !text.isEmpty {
                        requirements.append(AppRequirement(platform: child["heading"] as? String ?? "", text: text))
                    }
                }
            }
        }
        return StorePageDetails(purchases: purchases,
                                hasInAppPurchases: offer?["hasInAppPurchases"] as? Bool,
                                requirements: requirements,
                                releaseNotes: Self.releaseNotes(from: html))
    }

    private static func releaseNotes(from html: String) -> [AppReleaseNote] {
        guard let section = html.range(of: #"<section\b[^>]*\bid\s*=\s*["']mostRecentVersion["'][\s\S]*?</section>"#,
                                       options: [.regularExpression, .caseInsensitive]) else { return [] }
        let pattern = #"""
            <p\b[^>]*>\s*<span\b[^>]*>([\s\S]*?)</span>
            [\s\S]*?<span\b[^>]*>([\s\S]*?)</span>
            \s*<time\b[^>]*\bdatetime\s*=\s*["']([^"']+)["'][^>]*>
        """#
        let expression = try! NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace, .caseInsensitive])
        let text = String(html[section])
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match in
            func group(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                let value = String(text[range]).replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                let decoded = value.replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard let notes = group(1), let version = group(2), let date = group(3) else { return nil }
            return AppReleaseNote(version: version, releaseDate: date, notes: notes)
        }
    }
}

struct AppReleaseNote: Codable, Equatable, Sendable, Identifiable {
    let version: String
    let releaseDate: String
    let notes: String

    var id: String { "\(version)-\(releaseDate)" }

    var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: releaseDate)
    }
}

struct AppDetails: Codable, Equatable, Sendable {
    let listing: StoreListing
    let country: String
    let language: String
    let fetchedAt: Date
    let page: StorePageDetails?
    let schemaVersion: Int?

    static let currentSchemaVersion = 2

    var storeURL: URL { listing.storeURL(country: country, language: language) }
}

enum AppDetailsError: Error {
    case noIdentity, notFound, invalidResponse, invalidPage
}

protocol AppDetailsLoading: Sendable {
    func fetch(app: AppEntry, country: String, language: String) async throws -> AppDetails
}

actor AppStoreDetailsClient: AppDetailsLoading {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 18
            configuration.timeoutIntervalForResource = 30
            configuration.httpAdditionalHeaders = ["User-Agent": "AppNotes/1.0 (macOS; App information)"]
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetch(app: AppEntry, country: String, language: String) async throws -> AppDetails {
        guard app.appStoreID != nil || app.bundleID?.isEmpty == false else { throw AppDetailsError.noIdentity }
        var countries = [country, language == "zh-Hans" ? "cn" : "us", "us", "cn"]
        var seen = Set<String>()
        countries = countries.filter { seen.insert($0).inserted }
        var fallback: AppDetails?
        for region in countries {
            try Task.checkCancellation()
            var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
            lookup.queryItems = [
                URLQueryItem(name: "country", value: region),
                URLQueryItem(name: "lang", value: language == "zh-Hans" ? "zh_cn" : "en_us")
            ]
            if let id = app.appStoreID {
                lookup.queryItems?.append(URLQueryItem(name: "id", value: String(id)))
            } else {
                lookup.queryItems?.append(contentsOf: [
                    URLQueryItem(name: "bundleId", value: app.bundleID),
                    URLQueryItem(name: "entity", value: "macSoftware")
                ])
            }
            let data = try await response(from: lookup.url!)
            struct LookupResponse: Decodable { let results: [StoreListing] }
            guard let decoded = try? JSONDecoder().decode(LookupResponse.self, from: data) else {
                throw AppDetailsError.invalidResponse
            }
            guard let listing = decoded.results.first(where: { $0.matches(app) }) else { continue }
            var page: StorePageDetails?
            do {
                let pageData = try await response(from: listing.storeURL(country: region, language: language))
                if let html = String(data: pageData, encoding: .utf8) {
                    page = try StorePageDetails.parse(html, listing: listing, country: region)
                }
            } catch {
                try Task.checkCancellation()
                // Lookup data remains useful if the public page is unavailable or its structure changes.
            }
            let details = AppDetails(listing: listing, country: region, language: language, fetchedAt: Date(),
                                     page: page, schemaVersion: AppDetails.currentSchemaVersion)
            if page != nil { return details }
            if fallback == nil { fallback = details }
        }
        guard let fallback else { throw AppDetailsError.notFound }
        return fallback
    }

    private func response(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 5_000_000 else { throw AppDetailsError.invalidResponse }
        return data
    }
}

@MainActor
final class AppDetailsStore: ObservableObject {
    static let shared = AppDetailsStore()
    @Published private(set) var records: [String: AppDetails] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    private let loader: any AppDetailsLoading
    private let storeURL: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "AppNotes.details-cache")
    private var failedAttempts: Set<String> = []

    init(directory: URL? = nil, loader: any AppDetailsLoading = AppStoreDetailsClient(),
         now: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.now = now
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("app-details.json")
        if let data = try? Data(contentsOf: storeURL),
           let cache = try? JSONDecoder().decode([String: AppDetails].self, from: data) {
            records = cache
        }
    }

    static func country(for app: AppEntry, language: String) -> String {
        let region = app.storefrontCountryCode?.lowercased() ?? (language == "zh-Hans" ? "cn" : "us")
        return region.count == 2 && region.allSatisfy({ $0.isASCII && $0.isLetter }) ? region : "us"
    }

    static func key(for app: AppEntry, language: String) -> String {
        "\(app.path)|\(app.appStoreID.map(String.init) ?? "")|\(app.bundleID ?? "")|\(country(for: app, language: language))|\(language)"
    }

    func details(for app: AppEntry, language: String) -> AppDetails? {
        records[Self.key(for: app, language: language)]
    }

    func load(app: AppEntry, language: String, force: Bool = false) async {
        let key = Self.key(for: app, language: language)
        guard !loading.contains(key) else { return }
        if !force {
            if let cached = records[key],
               cached.schemaVersion == AppDetails.currentSchemaVersion,
               now().timeIntervalSince(cached.fetchedAt) < 86_400 { return }
            if failedAttempts.contains(key) { return }
        }
        loading.insert(key)
        errors.removeValue(forKey: key)
        defer { loading.remove(key) }
        do {
            let details = try await loader.fetch(app: app, country: Self.country(for: app, language: language), language: language)
            try Task.checkCancellation()
            guard details.listing.matches(app) else { throw AppDetailsError.notFound }
            records[key] = details
            failedAttempts.remove(key)
            save()
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            failedAttempts.insert(key)
            switch error {
            case AppDetailsError.notFound, AppDetailsError.noIdentity: errors[key] = "info.notFound"
            default: errors[key] = "info.loadFailed"
            }
        }
    }

    func flush() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        let url = storeURL
        queue.sync { try? data.write(to: url, options: .atomic) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        let url = storeURL
        queue.async { try? data.write(to: url, options: .atomic) }
    }
}

struct LocalAppDetails: Sendable {
    var build: String?
    var minimumSystem: String?
    var languages: [String] = []
    var copyright: String?

    static func read(path: String) -> LocalAppDetails {
        guard let bundle = Bundle(path: path) else { return LocalAppDetails() }
        return LocalAppDetails(build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                               minimumSystem: bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
                               languages: bundle.localizations.filter { $0 != "Base" },
                               copyright: bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String)
    }
}

extension URL {
    static func web(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}
