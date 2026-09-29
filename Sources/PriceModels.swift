import Foundation

enum PriceKind: String, Codable, CaseIterable, Sendable {
    case application, inAppPurchase
    var titleKey: String { "monitor.kind.\(rawValue)" }
    var symbol: String { self == .application ? "app.badge" : "diamond" }
}

struct WatchedApp: Codable, Equatable, Sendable {
    var storeID: Int64
    var bundleID: String
    var name: String
    var country: String
    var platform: String
    var artworkURL: String?

    var id: String { "\(storeID):\(country)" }
    // Keep identity language stable per storefront, independently of UI language.
    var purchaseLanguage: String { country == "cn" ? "zh-Hans" : "en" }
    var entry: AppEntry {
        AppEntry(path: "appnotes-watch/\(id)", name: name, bundleID: bundleID,
                 version: nil, appStoreID: storeID, storefrontCountryCode: country,
                 origin: .manual, artworkURL: artworkURL)
    }
    var storeURL: URL {
        var components = URLComponents(string: "https://apps.apple.com/\(country)/app/id\(storeID)")!
        components.queryItems = [URLQueryItem(name: "l", value: country == "cn" ? "zh-Hans-CN" : "en-US")]
        if platform == "mac-software" { components.queryItems?.append(URLQueryItem(name: "platform", value: "mac")) }
        return components.url!
    }
}

struct PriceQuote: Codable, Equatable, Sendable {
    var amount: Decimal
    var currency: String
    var observedAt: Date
    func formatted(locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currency
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
    }
}

struct ProductQuote: Sendable {
    var id: String
    var kind: PriceKind
    var name: String
    var price: PriceQuote
}

enum PriceFetchIssue: String, Codable, Sendable {
    case network, rate, region, response, identity, pageFormat, pageIdentity, price, purchases
    var messageKey: String { "monitor.error.\(rawValue)" }
}

struct PriceFetchFailure: Error, Codable, Equatable, Sendable {
    var issue: PriceFetchIssue
    var retryAfter: Date?
}

struct PriceSourceStatus: Codable, Equatable, Sendable {
    var attemptedAt: Date
    var failure: PriceFetchFailure?
    var succeeded: Bool { failure == nil }
}

struct PriceRequest: Sendable {
    var id: Int64
    var country: String
    var expectedBundle: String?
    var purchases: Bool = true
    var key: String { "\(id):\(country)" }
}

enum PurchaseComparison: String, Codable, Sendable {
    case comparable, duplicate, missingPrice, unsupportedCurrency, trial, invalidName
    var messageKey: String { "monitor.comparison.\(rawValue)" }
}

struct PurchaseAssessment: Sendable {
    var purchase: InAppPurchase
    var name: String
    var comparison: PurchaseComparison
    var amount: Decimal?
    func productID(language: String) -> String {
        language == "en" ? "iap:name:\(name)" : "iap:\(language):name:\(name)"
    }
}

struct PriceRefreshReport: Sendable {
    enum Disposition: String, Sendable { case updated, partial, failed, waiting, queued, skipped, cancelled }
    var disposition: Disposition
    var checked = 0
    var waiting = 0
    var retryAfter: Date?
    var messageKey: String { "monitor.refresh.\(disposition.rawValue)" }
}

struct PriceCandidate: Codable, Equatable, Sendable {
    var isFree: Bool
    var firstObservedAt: Date
}

struct ProductPriceState: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: PriceKind
    var name: String
    var latest: PriceQuote?
    var paidBaseline: PriceQuote?
    var candidate: PriceCandidate?
    var episodeID: UUID?
    var unavailable = false
}

struct PriceWatch: Codable, Equatable, Identifiable, Sendable {
    var app: WatchedApp
    var id: String { app.id }
    var revision = UUID()
    var isEnabled = true
    var watchesApplication = true
    var watchesPurchases = true
    var products: [ProductPriceState] = []
    var lastAttempt: Date?
    var lastSuccess: Date?
    var nextCheck = Date.distantPast
    var failureCount = 0
    var errorKey: String?
    var purchaseCoverageKey = "monitor.coverage.pending"
    var purchaseCount = 0
    var purchaseSnapshot: PurchaseSnapshot?
    var applicationStatus: PriceSourceStatus?
    var purchaseStatus: PriceSourceStatus?

    var request: PriceRequest {
        PriceRequest(id: app.storeID, country: app.country, expectedBundle: app.bundleID, purchases: watchesPurchases)
    }
    var retryAfter: Date? {
        [applicationStatus?.failure?.retryAfter, watchesPurchases ? purchaseStatus?.failure?.retryAfter : nil]
            .compactMap { $0 }.max()
    }
}

/// The public list is display data, not a set of stable product identities.
struct PurchaseSnapshot: Codable, Equatable, Sendable {
    var purchases: [InAppPurchase]
    var observedAt: Date
    var currency: String? = nil
}

enum PriceEventStatus: String, Codable, Sendable {
    case free, verifying, ended, unavailable
}

struct FreePriceEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var app: WatchedApp
    var productID: String
    var productName: String
    var kind: PriceKind
    var previous: PriceQuote
    var current: PriceQuote
    var discoveredAt: Date
    var confirmedAt: Date
    var status: PriceEventStatus = .free
    var endedAt: Date?
    var readAt: Date?
    var archivedAt: Date?

    var isUnread: Bool { readAt == nil && archivedAt == nil }
    func statusKey(now: Date = Date()) -> String {
        if status == .ended { return "monitor.status.ended" }
        if status == .unavailable || now.timeIntervalSince(current.observedAt) > PriceRules.freshness {
            return "monitor.status.stale"
        }
        if status == .verifying { return "monitor.status.verifying" }
        return "monitor.status.free"
    }
}

struct PriceMonitoringState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var automaticChecks = true
    var watches: [PriceWatch] = []
    var events: [FreePriceEvent] = []
    var lastCompleteCheck: Date?
}

struct PriceCheckResult: Sendable {
    var app: WatchedApp
    var quotes: [ProductQuote]
    var purchaseCoverageKey: String
    var purchaseCount: Int
    var applicationAvailable: Bool
    var purchaseSnapshot: PurchaseSnapshot? = nil
    var applicationStatus: PriceSourceStatus? = nil
    var purchaseStatus: PriceSourceStatus? = nil
    // Valid public list (even if some entries cannot be compared), not a request failure.
    var purchaseIdentityObserved: Bool = true
    var listing: StoreListing? = nil
}

enum PriceRules {
    static let interval: TimeInterval = 3_600
    static let confirmation: TimeInterval = 180
    static let candidateLifetime: TimeInterval = 1_800
    static let baselineLifetime: TimeInterval = 7 * 86_400
    static let freshness: TimeInterval = 7_200

    /// Price state and event changes are committed together by PriceRepository.
    static func apply(_ result: PriceCheckResult, to watch: inout PriceWatch,
                      events: inout [FreePriceEvent], now: Date) {
        watch.app = result.app
        watch.lastAttempt = now
        if watch.watchesPurchases {
            watch.purchaseCoverageKey = result.purchaseCoverageKey
            watch.purchaseCount = result.purchaseCount
        }
        watch.applicationStatus = result.applicationStatus ?? PriceSourceStatus(attemptedAt: now,
            failure: result.applicationAvailable ? nil : PriceFetchFailure(issue: .price))
        if watch.watchesPurchases {
            watch.purchaseStatus = result.purchaseStatus ?? PriceSourceStatus(attemptedAt: now,
                failure: result.purchaseCoverageKey == "monitor.coverage.unavailable" ? PriceFetchFailure(issue: .purchases) : nil)
        }
        // Retain the last observed list on network failure; the UI shows its timestamp.
        if let snapshot = result.purchaseSnapshot { watch.purchaseSnapshot = snapshot }
        watch.nextCheck = now.addingTimeInterval(interval)
        watch.errorKey = (watch.watchesApplication ? watch.applicationStatus?.failure : nil)?.issue.messageKey
            ?? (watch.watchesPurchases ? watch.purchaseStatus?.failure : nil)?.issue.messageKey
        if watch.errorKey != nil {
            watch.failureCount += 1
            let delays: [TimeInterval] = [300, 900, 3_600]
            watch.nextCheck = now.addingTimeInterval(delays[min(watch.failureCount - 1, 2)])
        } else { watch.failureCount = 0 }
        if let retry = watch.retryAfter { watch.nextCheck = max(watch.nextCheck, retry) }
        if watch.errorKey == nil { watch.lastSuccess = now }
        let quotes = result.quotes.filter {
            ($0.kind == .application && watch.watchesApplication) || ($0.kind == .inAppPurchase && watch.watchesPurchases)
        }
        let observed = Set(quotes.map(\.id))
        for index in watch.products.indices where !observed.contains(watch.products[index].id) {
            watch.products[index].unavailable = true
            watch.products[index].candidate = nil
            let identityLost = watch.products[index].kind == .inAppPurchase
                && watch.watchesPurchases && result.purchaseIdentityObserved
            let baselineExpired = watch.products[index].paidBaseline.map {
                !(0...baselineLifetime).contains(now.timeIntervalSince($0.observedAt))
            } ?? false
            // A transient outage interrupts confirmation, but preserves a recent paid observation.
            let scopeDisabled = watch.products[index].kind == .application ? !watch.watchesApplication : !watch.watchesPurchases
            if identityLost || baselineExpired || scopeDisabled { watch.products[index].paidBaseline = nil }
            if let episode = watch.products[index].episodeID,
               let event = events.firstIndex(where: { $0.id == episode && $0.status != .ended }) {
                events[event].status = .unavailable
            }
            if identityLost { watch.products[index].episodeID = nil }
        }
        for quote in quotes {
            if !watch.products.contains(where: { $0.id == quote.id }) {
                watch.products.append(ProductPriceState(id: quote.id, kind: quote.kind, name: quote.name))
            }
            guard let index = watch.products.firstIndex(where: { $0.id == quote.id }) else { continue }
            reduce(quote, app: watch.app, state: &watch.products[index], events: &events, now: now)
            if let candidate = watch.products[index].candidate {
                watch.nextCheck = min(watch.nextCheck, max(now.addingTimeInterval(60),
                    candidate.firstObservedAt.addingTimeInterval(confirmation)))
            }
        }
        if let retry = watch.retryAfter { watch.nextCheck = max(watch.nextCheck, retry) }
    }

    static func failed(_ failure: PriceFetchFailure, watch: inout PriceWatch,
                       events: inout [FreePriceEvent], now: Date) {
        let source = PriceSourceStatus(attemptedAt: now, failure: failure)
        let result = PriceCheckResult(app: watch.app, quotes: [], purchaseCoverageKey: "monitor.coverage.unavailable",
            purchaseCount: 0, applicationAvailable: false, applicationStatus: source,
            purchaseStatus: watch.watchesPurchases ? source : nil, purchaseIdentityObserved: false)
        apply(result, to: &watch, events: &events, now: now)
    }

    private static func reduce(_ quote: ProductQuote, app: WatchedApp,
                               state: inout ProductPriceState, events: inout [FreePriceEvent], now: Date) {
        guard quote.price.amount >= 0, quote.price.observedAt <= now,
              state.latest.map({ quote.price.observedAt > $0.observedAt }) ?? true else { return }
        if let previous = state.latest, previous.currency != quote.price.currency {
            if let episode = state.episodeID, let index = events.firstIndex(where: { $0.id == episode }) {
                events[index].status = .unavailable
            }
            state.paidBaseline = nil
            state.candidate = nil
            state.episodeID = nil
        }
        state.name = quote.name
        state.unavailable = false
        state.latest = quote.price
        if quote.kind == .inAppPurchase {
            // One explicit zero price starts an offer; repeated observations update it.
            state.candidate = nil
            if let episode = state.episodeID, let index = events.firstIndex(where: { $0.id == episode }) {
                events[index].current = quote.price
                events[index].status = quote.price.amount == 0 ? .free : .ended
                if quote.price.amount > 0 {
                    events[index].endedAt = now
                    state.episodeID = nil
                }
            } else if quote.price.amount == 0 {
                let id = UUID()
                events.append(FreePriceEvent(id: id, app: app, productID: quote.id, productName: quote.name,
                    kind: quote.kind, previous: state.paidBaseline ?? quote.price, current: quote.price,
                    discoveredAt: now, confirmedAt: now))
                state.episodeID = id
            }
            if quote.price.amount > 0 { state.paidBaseline = quote.price }
            return
        }
        if let candidate = state.candidate, now.timeIntervalSince(candidate.firstObservedAt) > candidateLifetime {
            state.candidate = nil
        }
        let free = quote.price.amount == 0
        if let episode = state.episodeID, let index = events.firstIndex(where: { $0.id == episode }) {
            events[index].current = quote.price
            if free {
                state.candidate = nil
                events[index].status = .free
            } else if confirmed(free: false, state: &state, now: now) {
                events[index].status = .ended
                events[index].endedAt = now
                state.episodeID = nil
                state.candidate = nil
                state.paidBaseline = quote.price
            } else {
                events[index].status = .verifying
            }
            return
        }
        if !free {
            state.paidBaseline = quote.price
            state.candidate = nil
            return
        }
        guard let baseline = state.paidBaseline, baseline.amount > 0,
              baseline.currency == quote.price.currency,
              (0...baselineLifetime).contains(now.timeIntervalSince(baseline.observedAt)) else {
            state.candidate = nil
            return // Already free when first observed is not a price drop.
        }
        let firstZero = state.candidate?.isFree == true ? state.candidate!.firstObservedAt : now
        if confirmed(free: true, state: &state, now: now) {
            let id = UUID()
            events.append(FreePriceEvent(id: id, app: app, productID: quote.id, productName: quote.name,
                kind: quote.kind, previous: baseline, current: quote.price,
                discoveredAt: firstZero, confirmedAt: now))
            state.episodeID = id
            state.candidate = nil
        }
    }

    private static func confirmed(free: Bool, state: inout ProductPriceState, now: Date) -> Bool {
        if let candidate = state.candidate, candidate.isFree == free {
            return now.timeIntervalSince(candidate.firstObservedAt) >= confirmation
        }
        state.candidate = PriceCandidate(isFree: free, firstObservedAt: now)
        return false
    }
}
