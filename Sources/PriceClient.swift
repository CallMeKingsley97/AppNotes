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
    func fetch(_ request: PriceRequest) async throws -> PriceCheckResult
    func lookup(_ requests: [PriceRequest]) async -> [String: Result<PriceCheckResult, PriceFetchFailure>]
    func complete(_ request: PriceRequest, lookup: PriceCheckResult) async throws -> PriceCheckResult
}

extension PriceLoading {
    func fetch(_ request: PriceRequest) async throws -> PriceCheckResult {
        try await fetch(id: request.id, country: request.country, expectedBundle: request.expectedBundle)
    }
    func lookup(_ requests: [PriceRequest]) async -> [String: Result<PriceCheckResult, PriceFetchFailure>] { [:] }
    func complete(_ request: PriceRequest, lookup: PriceCheckResult) async throws -> PriceCheckResult {
        try await fetch(request)
    }
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
        try await fetch(PriceRequest(id: id, country: country, expectedBundle: expectedBundle))
    }

    func fetch(_ request: PriceRequest) async throws -> PriceCheckResult {
        guard request.id > 0, Self.validCountry(request.country) else { throw PriceClientError.invalidLink }
        let data = try await response(Self.lookupURL(ids: [request.id], country: request.country))
        let listing = try Self.decodeListing(data, id: request.id, expectedBundle: request.expectedBundle)
        return try await complete(request, lookup: Self.base(listing, country: request.country))
    }

    /// Small batches only. Missing IDs are retried individually; malformed/mismatched records are not adopted.
    func lookup(_ requests: [PriceRequest]) async -> [String: Result<PriceCheckResult, PriceFetchFailure>] {
        var results: [String: Result<PriceCheckResult, PriceFetchFailure>] = [:]
        let groups = Dictionary(grouping: requests, by: \.country)
        for country in groups.keys.sorted() {
            let group = groups[country]!
            for start in stride(from: 0, to: group.count, by: 10) {
                let batch = Array(group[start..<min(start + 10, group.count)])
                do {
                    guard Self.validCountry(country), batch.allSatisfy({ $0.id > 0 }) else { throw PriceClientError.invalidLink }
                    let data = try await response(Self.lookupURL(ids: batch.map(\.id), country: country))
                    for request in batch {
                        do {
                            let listing = try Self.decodeListing(data, id: request.id, expectedBundle: request.expectedBundle)
                            results[request.key] = .success(try Self.base(listing, country: country))
                        } catch PriceClientError.notFound {
                            // The store will perform a single-ID lookup when this entry reaches the front.
                        } catch { results[request.key] = .failure(Self.failure(error)) }
                    }
                } catch {
                    for request in batch { results[request.key] = .failure(Self.failure(error)) }
                }
            }
        }
        return results
    }

    func complete(_ request: PriceRequest, lookup: PriceCheckResult) async throws -> PriceCheckResult {
        guard lookup.app.storeID == request.id, lookup.app.country == request.country,
              request.expectedBundle == nil || lookup.app.bundleID == request.expectedBundle else {
            throw PriceClientError.invalidIdentity
        }
        var result = lookup
        guard request.purchases else { return result }
        let app = result.app
        result.purchaseCoverageKey = "monitor.coverage.unavailable"
        do {
            let pageData = try await response(app.storeURL)
            try Task.checkCancellation()
            guard let listing = result.listing else { throw PriceClientError.invalidIdentity }
            let page = try StorePageDetails.parse(String(decoding: pageData, as: UTF8.self), listing: listing,
                country: request.country, languagePrefix: app.purchaseLanguage,
                platform: app.platform == "mac-software" ? "mac" : nil, includeIncompletePurchases: true,
                diagnoseIdentity: true)
            let now = Date()
            let currency = listing.currency
            // A declared IAP catalogue without a readable list is not evidence that all products disappeared.
            guard !page.purchases.isEmpty || page.hasInAppPurchases == false else {
                throw PriceFetchFailure(issue: .purchases)
            }
            result.purchaseSnapshot = PurchaseSnapshot(purchases: page.purchases, observedAt: now, currency: currency)
            result.purchaseStatus = PriceSourceStatus(attemptedAt: now)
            result.purchaseIdentityObserved = true
            if page.purchases.isEmpty {
                result.purchaseCoverageKey = "monitor.coverage.none"
            } else {
                let quotes = currency.map {
                    PublicPurchasePrices.quotes(from: page.purchases, currency: $0, observedAt: now,
                        language: app.purchaseLanguage)
                } ?? []
                result.quotes += quotes
                result.purchaseCount = quotes.count
                let allReadable = PublicPurchasePrices.assess(page.purchases, currency: currency)
                    .allSatisfy { $0.comparison == .comparable }
                result.purchaseCoverageKey = allReadable ? "monitor.coverage.public" : "monitor.coverage.partial"
            }
        } catch {
            try Task.checkCancellation()
            result.purchaseStatus = PriceSourceStatus(attemptedAt: Date(), failure: Self.failure(error))
            result.purchaseIdentityObserved = false
        }
        return result
    }

    static func failure(_ error: Error) -> PriceFetchFailure {
        if let failure = error as? PriceFetchFailure { return failure }
        switch error {
        case PriceClientError.rateLimited(let date), AppleRequestError.rateLimited(let date):
            return PriceFetchFailure(issue: .rate, retryAfter: date)
        case PriceClientError.notFound: return PriceFetchFailure(issue: .region)
        case PriceClientError.invalidIdentity: return PriceFetchFailure(issue: .identity)
        case PriceClientError.invalidResponse, PriceClientError.invalidLink: return PriceFetchFailure(issue: .response)
        case AppDetailsError.invalidPageIdentity: return PriceFetchFailure(issue: .pageIdentity)
        case AppDetailsError.invalidPage: return PriceFetchFailure(issue: .pageFormat)
        default: return PriceFetchFailure(issue: .network)
        }
    }

    private static func validCountry(_ country: String) -> Bool {
        country.count == 2 && country.allSatisfy { $0.isASCII && $0.isLowercase }
    }

    private static func lookupURL(ids: [Int64], country: String) -> URL {
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [URLQueryItem(name: "id", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "lang", value: country == "cn" ? "zh_cn" : "en_us")]
        return url.url!
    }

    private static func base(_ listing: Listing, country: String) throws -> PriceCheckResult {
        let app = WatchedApp(storeID: listing.trackId, bundleID: listing.bundleId, name: listing.trackName,
            country: country, platform: listing.kind, artworkURL: listing.artworkUrl512 ?? listing.artworkUrl100)
        let now = Date()
        var quotes: [ProductQuote] = []
        if let amount = listing.price, amount >= 0, let currency = listing.currency, validCurrency(currency) {
            quotes.append(ProductQuote(id: "app", kind: .application, name: app.name,
                price: PriceQuote(amount: amount, currency: currency, observedAt: now)))
        }
        return PriceCheckResult(app: app, quotes: quotes, purchaseCoverageKey: "monitor.coverage.pending",
            purchaseCount: 0, applicationAvailable: !quotes.isEmpty,
            applicationStatus: PriceSourceStatus(attemptedAt: now, failure: quotes.isEmpty ? PriceFetchFailure(issue: .price) : nil),
            purchaseIdentityObserved: false,
            listing: try JSONDecoder().decode(StoreListing.self, from: JSONEncoder().encode(listing)))
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
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = root["results"] as? [[String: Any]] else { throw PriceClientError.invalidResponse }
        let matching = records.filter { ($0["trackId"] as? NSNumber)?.int64Value == id }
        guard !matching.isEmpty else { throw PriceClientError.notFound }
        guard matching.count == 1 else { throw PriceClientError.invalidIdentity }
        guard let encoded = try? JSONSerialization.data(withJSONObject: matching[0]),
              let listing = try? JSONDecoder().decode(Listing.self, from: encoded) else { throw PriceClientError.invalidResponse }
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

/// Read explicit prices; same-name rows use the lowest listed price for zero-price detection.
enum PublicPurchasePrices {
    static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let supportedCurrencies: Set<String> = ["CNY", "USD", "JPY", "GBP", "EUR", "HKD", "TWD", "CAD", "AUD", "KRW", "SGD"]

    static func assess(_ purchases: [InAppPurchase], currency: String?) -> [PurchaseAssessment] {
        return purchases.map { purchase in
            let name = nameKey(purchase.name)
            let reason: PurchaseComparison
            let value = currency.flatMap { amount(purchase.price, currency: $0) }
            if name.isEmpty { reason = .invalidName }
            else if currency.map({ supportedCurrencies.contains($0) }) != true { reason = .unsupportedCurrency }
            else if value == nil { reason = .missingPrice }
            else { reason = .comparable }
            return PurchaseAssessment(purchase: purchase, name: name, comparison: reason, amount: value)
        }
    }

    static func quotes(from purchases: [InAppPurchase], currency: String, observedAt: Date,
                       language: String = "en") -> [ProductQuote] {
        let readable = assess(purchases, currency: currency).filter { $0.comparison == .comparable }
        return Dictionary(grouping: readable, by: \.name).values.compactMap { items in
            guard let item = items.min(by: { $0.amount! < $1.amount! }), let amount = item.amount else { return nil }
            return ProductQuote(id: item.productID(language: language), kind: .inAppPurchase, name: item.name,
                price: PriceQuote(amount: amount, currency: currency, observedAt: observedAt))
        }.sorted { $0.name < $1.name }
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
