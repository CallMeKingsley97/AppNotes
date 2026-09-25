import Foundation

enum PriceClientError: Error {
    case invalidLink, notFound, invalidResponse, invalidIdentity, rateLimited(Date)

    var messageKey: String {
        switch self {
        case .invalidLink: return "monitor.error.link"
        case .notFound: return "monitor.error.region"
        case .invalidIdentity: return "monitor.error.identity"
        case .rateLimited: return "monitor.error.rate"
        case .invalidResponse: return "monitor.error.response"
        }
    }
}

protocol PriceLoading: Sendable {
    func fetch(id: Int64, country: String, expectedBundle: String?) async throws -> PriceCheckResult
}

struct AppStorePriceClient: PriceLoading {
    private let session: URLSession
    private let queue: AppleRequestQueue

    init(session: URLSession? = nil, queue: AppleRequestQueue = .shared) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "AppNotes/1.0 (macOS; Price monitoring)"]
        self.session = session ?? URLSession(configuration: configuration)
        self.queue = queue
    }

    func fetch(id: Int64, country: String, expectedBundle: String?) async throws -> PriceCheckResult {
        guard id > 0, country.count == 2, country.allSatisfy({ $0.isASCII && $0.isLowercase }) else {
            throw PriceClientError.invalidLink
        }
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [URLQueryItem(name: "id", value: String(id)), URLQueryItem(name: "country", value: country),
                         URLQueryItem(name: "lang", value: country == "cn" ? "zh_cn" : "en_us")]
        let data = try await response(url.url!)
        let listing = try Self.decodeListing(data, id: id, expectedBundle: expectedBundle)
        let app = WatchedApp(storeID: id, bundleID: listing.bundleId, name: listing.trackName,
                             country: country, platform: listing.kind, artworkURL: listing.artworkUrl512 ?? listing.artworkUrl100)
        let now = Date()
        var quotes: [ProductQuote] = []
        if let amount = listing.price, amount >= 0, let currency = listing.currency, Self.validCurrency(currency) {
            quotes.append(ProductQuote(id: "app", kind: .application, name: app.name,
                                       price: PriceQuote(amount: amount, currency: currency, observedAt: now)))
        }
        var coverage = "monitor.coverage.unavailable"
        var purchaseCount = 0
        var purchaseSnapshot: PurchaseSnapshot?
        do {
            // The storefront's fixed language is part of name-based identity, not the UI language.
            let pageData = try await response(app.storeURL)
            try Task.checkCancellation()
            let storeListing = try JSONDecoder().decode(StoreListing.self, from: JSONEncoder().encode(listing))
            let page = try StorePageDetails.parse(String(decoding: pageData, as: UTF8.self), listing: storeListing, country: country,
                                                  languagePrefix: app.purchaseLanguage, platform: listing.kind == "mac-software" ? "mac" : nil,
                                                  includeIncompletePurchases: true)
            purchaseSnapshot = PurchaseSnapshot(purchases: page.purchases, observedAt: Date())
            if page.hasInAppPurchases == false {
                coverage = "monitor.coverage.none"
            } else if !page.purchases.isEmpty, let currency = listing.currency, Self.validCurrency(currency) {
                var parsed = PublicPurchasePrices.quotes(from: page.purchases, currency: currency, observedAt: Date())
                // Do not compare new Chinese names with legacy English baselines, even if a name is unchanged.
                if app.purchaseLanguage != "en" {
                    for index in parsed.indices { parsed[index].id = "iap:\(app.purchaseLanguage):name:\(parsed[index].name)" }
                }
                quotes += parsed
                purchaseCount = parsed.count
                coverage = parsed.count == page.purchases.count ? "monitor.coverage.public" : "monitor.coverage.partial"
            }
        } catch {
            try Task.checkCancellation()
            // A valid download price remains usable when the public purchase shelf fails.
        }
        return PriceCheckResult(app: app, quotes: quotes, purchaseCoverageKey: coverage,
                                purchaseCount: purchaseCount, applicationAvailable: quotes.contains { $0.kind == .application },
                                purchaseSnapshot: purchaseSnapshot)
    }

    struct Listing: Codable {
        var trackId: Int64
        var wrapperType: String
        var bundleId: String
        var trackName: String
        var kind: String
        var price: Decimal?
        var currency: String?
        var artworkUrl512: String?
        var artworkUrl100: String?
    }

    static func decodeListing(_ data: Data, id: Int64, expectedBundle: String?) throws -> Listing {
        struct Response: Decodable { var results: [Listing] }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw PriceClientError.invalidResponse }
        guard let listing = decoded.results.first(where: { $0.trackId == id }) else { throw PriceClientError.notFound }
        guard listing.wrapperType == "software", ["software", "mac-software"].contains(listing.kind),
              !listing.bundleId.isEmpty, !listing.trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedBundle == nil || listing.bundleId == expectedBundle else { throw PriceClientError.invalidIdentity }
        return listing
    }

    private static func validCurrency(_ currency: String) -> Bool {
        currency.count == 3 && currency.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    private func response(_ url: URL) async throws -> Data {
        let response: (Data, URLResponse)
        do { response = try await queue.data(from: url, session: session) }
        catch AppleRequestError.rateLimited(let date) { throw PriceClientError.rateLimited(date) }
        let (data, raw) = response
        guard let http = raw as? HTTPURLResponse else { throw PriceClientError.invalidResponse }
        if http.statusCode == 429 {
            throw PriceClientError.rateLimited(AppleRequestQueue.retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: Date()))
        }
        guard (200..<300).contains(http.statusCode), data.count <= 8_000_000 else { throw PriceClientError.invalidResponse }
        return data
    }
}

/// Public shelves expose names, not StoreKit IDs. Only unique exact names may be compared.
/// Removed, renamed, ambiguous or malformed entries break the baseline instead of implying free.
enum PublicPurchasePrices {
    static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func quotes(from purchases: [InAppPurchase], currency: String, observedAt: Date) -> [ProductQuote] {
        let groups = Dictionary(grouping: purchases, by: { nameKey($0.name) })
        return groups.keys.sorted().compactMap { name in
            guard !name.isEmpty, let matches = groups[name], matches.count == 1,
                  !name.lowercased().contains("trial"), !name.contains("试用"),
                  let amount = amount(matches[0].price, currency: currency) else { return nil }
            return ProductQuote(id: "iap:name:\(name)", kind: .inAppPurchase, name: name,
                                price: PriceQuote(amount: amount, currency: currency, observedAt: observedAt))
        }
    }

    static func amount(_ text: String, currency: String) -> Decimal? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["free", "免费"].contains(raw.lowercased()) { return 0 }
        let symbols: [String: [String]] = [
            "CNY": ["CN¥", "RMB", "¥", "￥"], "USD": ["US$", "$"], "JPY": ["JP¥", "¥", "￥"],
            "GBP": ["£"], "EUR": ["€"], "HKD": ["HK$", "$"], "TWD": ["NT$", "$"],
            "CAD": ["CA$", "C$", "$"], "AUD": ["AU$", "A$", "$"], "KRW": ["₩"], "SGD": ["S$", "$"],
        ]
        guard let marks = symbols[currency] else { return nil }
        var number = raw.filter { !$0.isWhitespace }
        var foundCurrency = false
        for mark in [currency] + marks {
            if number.hasPrefix(mark) { number.removeFirst(mark.count); foundCurrency = true; break }
            if number.hasSuffix(mark) { number.removeLast(mark.count); foundCurrency = true; break }
        }
        guard foundCurrency, !number.isEmpty else { return nil }
        // Accept two unambiguous conventions. No loose NumberFormatter prefix parsing.
        let dot = #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#
        let comma = #"^(?:[0-9]+|[0-9]{1,3}(?:\.[0-9]{3})+),[0-9]{2}$"#
        if number.range(of: dot, options: .regularExpression) != nil {
            number = number.replacingOccurrences(of: ",", with: "")
        } else if number.range(of: comma, options: .regularExpression) != nil {
            number = number.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else { return nil }
        return Decimal(string: number, locale: Locale(identifier: "en_US_POSIX"))
    }
}
