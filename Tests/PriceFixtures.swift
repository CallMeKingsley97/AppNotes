import Foundation

enum PriceFixtures {
    static let app = WatchedApp(storeID: 6757103562, bundleID: "com.example.mac", name: "Paper Studio",
                                country: "cn", platform: "mac-software", artworkURL: nil)
    static func result(at date: Date, appPrice: Decimal = 28, purchasePrice: Decimal = 68,
                       app: WatchedApp = app) -> PriceCheckResult {
        PriceCheckResult(app: app, quotes: [
            ProductQuote(id: "app", kind: .application, name: app.name,
                         price: PriceQuote(amount: appPrice, currency: "CNY", observedAt: date)),
            ProductQuote(id: "iap:name:Lifetime Pro", kind: .inAppPurchase, name: "Lifetime Pro",
                         price: PriceQuote(amount: purchasePrice, currency: "CNY", observedAt: date))
        ], purchaseCoverageKey: "monitor.coverage.public", purchaseCount: 1, applicationAvailable: true)
    }
    static func state(now: Date = Date()) -> PriceMonitoringState {
        var state = PriceMonitoringState()
        for (index, name) in ["Paper Studio", "Focus Timer", "Canvas — Creative Workspace"].enumerated() {
            var app = Self.app
            app.storeID += Int64(index)
            app.name = name
            app.bundleID += ".\(index)"
            var watch = PriceWatch(app: app)
            PriceRules.apply(result(at: now.addingTimeInterval(-7_200), app: app), to: &watch, events: &state.events, now: now.addingTimeInterval(-7_200))
            for offset in [-600.0, -400.0] {
                let date = now.addingTimeInterval(offset)
                PriceRules.apply(result(at: date, appPrice: index == 1 ? 28 : 0,
                                        purchasePrice: index == 0 ? 0 : 68, app: app), to: &watch, events: &state.events, now: date)
            }
            if index == 1 { watch.isEnabled = false }
            state.watches.append(watch)
        }
        state.lastCompleteCheck = now.addingTimeInterval(-400)
        return state
    }
}

struct OfflinePriceLoader: PriceLoading {
    func fetch(id: Int64, country: String, expectedBundle: String?) async throws -> PriceCheckResult {
        throw URLError(.notConnectedToInternet)
    }
}

struct FixturePriceLoader: PriceLoading {
    func fetch(id: Int64, country: String, expectedBundle: String?) async throws -> PriceCheckResult {
        var app = PriceFixtures.app
        app.storeID = id
        app.country = country
        app.bundleID = expectedBundle ?? "com.example.verified"
        return PriceFixtures.result(at: Date(), app: app)
    }
}
