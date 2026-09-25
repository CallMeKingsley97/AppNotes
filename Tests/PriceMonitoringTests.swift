import Foundation

private final class PriceURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Retry-After": "120"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor HeldPriceLoader: PriceLoading {
    var calls = 0
    private var pending: CheckedContinuation<PriceCheckResult, Error>?
    private var arrived: CheckedContinuation<Void, Never>?
    func fetch(id: Int64, country: String, expectedBundle: String?) async throws -> PriceCheckResult {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            arrived?.resume()
            arrived = nil
        }
    }
    func waitForCall() async {
        if calls > 0 { return }
        await withCheckedContinuation { arrived = $0 }
    }
    func finish(_ result: PriceCheckResult) { pending?.resume(returning: result); pending = nil }
}

private actor CountingPriceLoader: PriceLoading {
    var calls = 0
    func fetch(id: Int64, country: String, expectedBundle: String?) async throws -> PriceCheckResult {
        calls += 1
        return PriceFixtures.result(at: Date())
    }
}

@main
struct PriceMonitoringTests {
    @MainActor static func main() async throws {
        rules()
        purchases()
        try await client()
        try await storage()
        try await races()
        if CommandLine.arguments.contains("--live") {
            let result = try await AppStorePriceClient().fetch(id: 6757103562, country: "cn", expectedBundle: nil)
            precondition(result.applicationAvailable)
            precondition(result.purchaseCount > 0)
            print("Live: fixed CN storefront, download price and \(result.purchaseCount) uniquely named public purchases parsed; no offer inferred.")
            let copyHistory = try await AppStorePriceClient().fetch(id: 6757165518, country: "cn",
                                                                  expectedBundle: "com.huagx.copyhistory")
            precondition(copyHistory.applicationAvailable && copyHistory.purchaseCount > 0)
            precondition(copyHistory.purchaseSnapshot?.purchases.count == 5)
            precondition(copyHistory.purchaseCount == 3)
            precondition(copyHistory.purchaseSnapshot?.purchases.contains { $0.name == "CopyHistory Pro 永久激活" && $0.price == "¥58.00" } == true)
            print("Live CopyHistory: \(copyHistory.purchaseCount) uniquely named purchases, coverage=\(copyHistory.purchaseCoverageKey)")
        }
        print("Passed: price transitions, separate app/IAP events, confirmation and deduplication, parsing, fixed storefront, persistence, undo and in-flight edits.")
    }

    private static func rules() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var watch = PriceWatch(app: PriceFixtures.app)
        var events: [FreePriceEvent] = []
        func apply(_ seconds: Double, _ app: Decimal, _ iap: Decimal) {
            let date = start.addingTimeInterval(seconds)
            PriceRules.apply(PriceFixtures.result(at: date, appPrice: app, purchasePrice: iap), to: &watch, events: &events, now: date)
        }
        apply(0, 0, 0)
        apply(200, 0, 0)
        precondition(events.isEmpty, "Already-free apps must not notify")
        apply(400, 28, 68)
        apply(600, 0, 0)
        apply(779, 0, 0)
        precondition(events.isEmpty, "Confirmation must wait at least three minutes")
        apply(780, 0, 0)
        precondition(events.count == 2 && Set(events.map(\.kind)).count == 2)
        let firstIDs = events.map(\.id)
        apply(900, 0, 0)
        precondition(events.map(\.id) == firstIDs, "Continuous free period must not replay")
        apply(1_000, 28, 0)
        precondition(events.first { $0.kind == .application }?.status == .verifying)
        apply(1_180, 28, 0)
        precondition(events.first { $0.kind == .application }?.status == .ended)
        apply(1_300, 0, 0)
        apply(1_480, 0, 0)
        precondition(events.count == 3, "Paid then free should create a new episode")
        precondition(events.filter { $0.kind == .inAppPurchase }.count == 1)
        let saved = try! JSONDecoder().decode(PriceWatch.self, from: JSONEncoder().encode(watch))
        watch = saved
        apply(1_600, 0, 0)
        precondition(events.count == 3, "Restart must retain episode IDs")
        precondition(events.allSatisfy(\.isUnread), "Ended offers still count until read")

        var fresh = PriceWatch(app: PriceFixtures.app)
        var empty: [FreePriceEvent] = []
        let paid = PriceFixtures.result(at: start)
        PriceRules.apply(paid, to: &fresh, events: &empty, now: start)
        for seconds in [8 * 86_400.0, 8 * 86_400.0 + 180] {
            let date = start.addingTimeInterval(seconds)
            PriceRules.apply(PriceFixtures.result(at: date, appPrice: 0, purchasePrice: 0), to: &fresh, events: &empty, now: date)
        }
        precondition(empty.isEmpty, "Baseline older than seven days must not notify")
        fresh = PriceWatch(app: PriceFixtures.app)
        PriceRules.apply(paid, to: &fresh, events: &empty, now: start)
        for seconds in [200.0, 2_100, 2_280] {
            let date = start.addingTimeInterval(seconds)
            PriceRules.apply(PriceFixtures.result(at: date, appPrice: 0), to: &fresh, events: &empty, now: date)
            if seconds == 2_100 { precondition(empty.isEmpty, "Expired candidate needs a new confirmation") }
        }
        precondition(empty.count == 1)

        fresh = PriceWatch(app: PriceFixtures.app)
        empty = []
        PriceRules.apply(paid, to: &fresh, events: &empty, now: start)
        var missing = PriceFixtures.result(at: start.addingTimeInterval(100))
        missing.quotes.removeAll { $0.kind == .inAppPurchase }
        PriceRules.apply(missing, to: &fresh, events: &empty, now: start.addingTimeInterval(100))
        precondition(fresh.products.first { $0.kind == .inAppPurchase }?.paidBaseline == nil)
        for seconds in [200.0, 380] {
            let date = start.addingTimeInterval(seconds)
            var changed = PriceFixtures.result(at: date, appPrice: 0, purchasePrice: 0)
            changed.quotes[0].price.currency = "USD"
            PriceRules.apply(changed, to: &fresh, events: &empty, now: date)
        }
        precondition(empty.isEmpty, "Currency change and missing IAP must reset baselines")
        let latest = fresh.products.map(\.latest)
        PriceRules.apply(paid, to: &fresh, events: &empty, now: start.addingTimeInterval(400))
        precondition(fresh.products.map(\.latest) == latest, "Old responses must not replace newer prices")
    }

    private static func purchases() {
        let date = Date()
        let entries = [InAppPurchase(name: "Lifetime Pro", price: "¥68.00"),
                       InAppPurchase(name: "Duplicate", price: "¥28.00"),
                       InAppPurchase(name: "Duplicate", price: "Free"),
                       InAppPurchase(name: "7 day trial", price: "Free"),
                       InAppPurchase(name: "Monthly", price: "¥0 per month"),
                       InAppPurchase(name: "Unknown", price: ""),
                       InAppPurchase(name: "Other", price: "$0.00")]
        let quotes = PublicPurchasePrices.quotes(from: entries, currency: "CNY", observedAt: date)
        precondition(quotes.count == 1 && quotes[0].price.amount == 68)
        precondition(PublicPurchasePrices.amount("Free", currency: "USD") == 0)
        precondition(PublicPurchasePrices.amount("¥0.00", currency: "CNY") == 0)
        precondition(PublicPurchasePrices.amount("1.234,56 €", currency: "EUR") == Decimal(string: "1234.56"))
        precondition(PublicPurchasePrices.amount("$1,234.56", currency: "USD") == Decimal(string: "1234.56"))
        for text in ["Free trial", "¥-1", "¥nan", "¥0 today", "0", "$0", "¥1..0", "¥"] {
            precondition(PublicPurchasePrices.amount(text, currency: "CNY") == nil, text)
        }
        let names = [InAppPurchase(name: " Pro  Life ", price: "¥1"), InAppPurchase(name: "Pro Life", price: "¥0")]
        precondition(PublicPurchasePrices.quotes(from: names, currency: "CNY", observedAt: date).isEmpty)
        precondition(PublicPurchasePrices.nameKey("Cafe\u{301}") == PublicPurchasePrices.nameKey("Café"))
    }

    private static func client() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PriceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = AppStorePriceClient(session: session, queue: AppleRequestQueue(spacing: 0))
        let listing = try DetailsFixtures.listing()
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(listing)) as! [String: Any]
        raw["wrapperType"] = "software"
        raw["price"] = 28
        let data = try JSONSerialization.data(withJSONObject: ["results": [raw]])
        let html = try DetailsFixtures.pageHTML(listing: listing, language: "zh-Hans")
        PriceURLProtocol.handler = { request in
            let url = request.url!
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            if url.host == "itunes.apple.com" {
                precondition(items.contains(URLQueryItem(name: "country", value: "cn")))
                precondition(items.contains(URLQueryItem(name: "lang", value: "zh_cn")))
                return (200, data)
            }
            precondition(url.path == "/cn/app/id\(listing.trackId)")
            precondition(items.contains(URLQueryItem(name: "l", value: "zh-Hans-CN")))
            precondition(items.contains(URLQueryItem(name: "platform", value: "mac")))
            precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (200, Data(html.utf8))
        }
        let result = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: listing.bundleId)
        precondition(result.applicationAvailable && result.purchaseCount == 2)
        precondition(result.purchaseCoverageKey == "monitor.coverage.partial")
        precondition(result.purchaseSnapshot?.purchases.count == 4, "Display must retain duplicate names and prices")
        precondition(result.quotes.filter { $0.kind == .inAppPurchase }.allSatisfy { $0.id.hasPrefix("iap:zh-Hans:name:") },
                     "New Chinese identities must not reuse legacy English baselines")
        var watch = PriceWatch(app: result.app)
        var events: [FreePriceEvent] = []
        PriceRules.apply(result, to: &watch, events: &events, now: Date())
        let restored = try JSONDecoder().decode(PriceWatch.self, from: JSONEncoder().encode(watch))
        precondition(restored.purchaseSnapshot == result.purchaseSnapshot)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(watch)) as! [String: Any]
        legacy.removeValue(forKey: "purchaseSnapshot")
        let legacyWatch = try JSONDecoder().decode(PriceWatch.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyWatch.purchaseSnapshot == nil, "Existing saved watches remain readable")
        for (intentPlatform, appPlatforms, expectedCount) in [
            (nil as String?, ["mac"], 2),
            (nil, ["iphone"], 0),
            (nil, ["mac", "iphone"], 0),
            (nil, [], 0),
            ("iphone", ["mac"], 0)
        ] {
            let page = try DetailsFixtures.pageHTML(listing: listing, language: "zh-Hans",
                                                   intentPlatform: intentPlatform, appPlatforms: appPlatforms)
            PriceURLProtocol.handler = { request in
                (200, request.url!.host == "itunes.apple.com" ? data : Data(page.utf8))
            }
            let checked = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: listing.bundleId)
            precondition(checked.purchaseCount == expectedCount,
                         "Missing intent platform requires unambiguous product platform evidence")
        }
        for page in [html.replacingOccurrences(of: "\"cn\"", with: "\"us\""),
                     html.replacingOccurrences(of: "zh-Hans", with: "en-GB"),
                     html.replacingOccurrences(of: "\"mac\"", with: "\"iphone\""), "<html></html>"] {
            PriceURLProtocol.handler = { request in (200, request.url!.host == "itunes.apple.com" ? data : Data(page.utf8)) }
            let partial = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: listing.bundleId)
            precondition(partial.applicationAvailable && partial.purchaseCount == 0)
            precondition(partial.purchaseCoverageKey == "monitor.coverage.unavailable")
            precondition(partial.purchaseSnapshot == nil)
            PriceRules.apply(partial, to: &watch, events: &events, now: Date())
            precondition(watch.purchaseSnapshot == result.purchaseSnapshot, "Failed requests retain the dated last observation")
        }
        let malformed = html.replacingOccurrences(of: "¥28.00", with: "")
        let parsed = try StorePageDetails.parse(malformed, listing: listing, country: "cn", includeIncompletePurchases: true)
        precondition(parsed.purchases.count == 4)
        precondition(PublicPurchasePrices.quotes(from: parsed.purchases, currency: "CNY", observedAt: Date()).count == 2,
                     "A duplicate with a missing price is still ambiguous")
        let duplicates = html.replacingOccurrences(of: "Pro 终身会员", with: "Ultimate")
            .replacingOccurrences(of: "Ultimate 终身会员", with: "Ultimate")
        PriceURLProtocol.handler = { request in
            (200, request.url!.host == "itunes.apple.com" ? data : Data(duplicates.utf8))
        }
        let duplicateResult = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: listing.bundleId)
        precondition(duplicateResult.purchaseSnapshot?.purchases.count == 4 && duplicateResult.purchaseCount == 0,
                     "Even an entirely ambiguous list must remain visible")
        precondition(duplicateResult.purchaseCoverageKey == "monitor.coverage.partial")
        let missingPrice = malformed.replacingOccurrences(of: "¥68.00", with: "")
        PriceURLProtocol.handler = { request in
            (200, request.url!.host == "itunes.apple.com" ? data : Data(missingPrice.utf8))
        }
        let incomplete = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: listing.bundleId)
        precondition(incomplete.purchaseSnapshot?.purchases.count == 4 && incomplete.purchaseCount == 1)
        precondition(incomplete.purchaseSnapshot?.purchases.contains { $0.price.isEmpty } == true)
        let noPurchases = try DetailsFixtures.pageHTML(listing: listing, purchases: false)
        PriceURLProtocol.handler = { request in
            (200, request.url!.host == "itunes.apple.com" ? data : Data(noPurchases.utf8))
        }
        let empty = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: listing.bundleId)
        PriceRules.apply(empty, to: &watch, events: &events, now: Date())
        precondition(watch.purchaseSnapshot?.purchases.isEmpty == true, "A successful empty list replaces the old snapshot")
        let english = try DetailsFixtures.pageHTML(listing: listing, language: "en", country: "us")
        PriceURLProtocol.handler = { request in
            (200, request.url!.host == "itunes.apple.com" ? data : Data(english.utf8))
        }
        let us = try await client.fetch(id: listing.trackId, country: "us", expectedBundle: listing.bundleId)
        precondition(us.purchaseSnapshot?.purchases.count == 4 && us.purchaseCount == 2)
        precondition(us.quotes.filter { $0.kind == .inAppPurchase }.allSatisfy { $0.id.hasPrefix("iap:name:") },
                     "English storefront identity stays unchanged")
        PriceURLProtocol.handler = { _ in (200, Data(#"{"results":[]}"#.utf8)) }
        do {
            _ = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: nil)
            preconditionFailure("Missing regional record must fail without a fallback")
        } catch PriceClientError.notFound {}
        PriceURLProtocol.handler = { _ in (200, data) }
        do {
            _ = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: "wrong.bundle")
            preconditionFailure("Identity mismatch must fail")
        } catch PriceClientError.invalidIdentity {}
        PriceURLProtocol.handler = { _ in (429, Data()) }
        do {
            _ = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: nil)
            preconditionFailure("Rate limit must fail, not imply free")
        } catch PriceClientError.rateLimited(let date) { precondition(date.timeIntervalSinceNow > 100) }
        PriceURLProtocol.handler = { _ in preconditionFailure("Cooldown must not make another request") }
        do {
            _ = try await client.fetch(id: listing.trackId, country: "cn", expectedBundle: nil)
            preconditionFailure("Cooldown must be honored")
        } catch PriceClientError.rateLimited {}
        precondition(AppleRequestQueue.retryDate("nonsense", now: Date()).timeIntervalSinceNow > 50)
    }

    @MainActor private static func storage() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("AppNotesPriceTests-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("price-monitoring.json")
        let initial = PriceFixtures.state()
        try JSONEncoder().encode(initial).write(to: url)
        let store = PriceMonitorStore(directory: base, loader: OfflinePriceLoader())
        let ids = Set(store.state.events.map(\.id))
        await store.markRead(ids, read: true, undoable: true)
        precondition(store.unreadCount == 0)
        await store.undo()
        precondition(store.unreadCount == ids.count)
        let id = ids.first!
        await store.archive(id, archived: true)
        precondition(store.unreadCount == ids.count - 1)
        await store.undo()
        precondition(store.unreadCount == ids.count)
        let reload = PriceMonitorStore(directory: base, loader: OfflinePriceLoader())
        precondition(reload.state == store.state, "Read state and episodes must survive reload")
        await store.remove(watchID: initial.watches[0].id)
        precondition(store.state.watches.count == initial.watches.count - 1 && store.state.events.count == initial.events.count)
        await store.undo()
        precondition(store.state.watches.count == initial.watches.count)
        await store.markRead(ids, read: true, undoable: true)
        var newApp = PriceFixtures.app
        newApp.storeID += 10
        newApp.bundleID += ".new"
        for offset in [-900.0, -500.0, -300.0] {
            let date = Date().addingTimeInterval(offset)
            let old = store.watch(for: newApp.id)
            let result = PriceFixtures.result(at: date, appPrice: offset == -900 ? 28 : 0, app: newApp)
            let saved = await store.follow(result, application: true, purchases: false, replacing: old, now: date)
            precondition(saved)
        }
        let newer = store.state.events.first { $0.app.id == newApp.id }!
        await store.markRead([newer.id], read: true)
        await store.undo()
        precondition(store.state.events.first { $0.id == newer.id }?.readAt != nil,
                     "Undo all-read must not overwrite later events")
        precondition(store.state.events.filter { ids.contains($0.id) }.allSatisfy(\.isUnread))
        await store.setAutomaticChecks(false)
        precondition(!PriceRepository.load(url).state.automaticChecks)
        let backup = try Data(contentsOf: url.appendingPathExtension("backup"))
        try Data("broken".utf8).write(to: url)
        let recovered = PriceRepository.load(url)
        precondition(recovered.writable && recovered.errorKey == "monitor.error.recovered")
        precondition(recovered.state == (try! JSONDecoder().decode(PriceMonitoringState.self, from: backup)))
        try Data("also broken".utf8).write(to: url.appendingPathExtension("backup"))
        precondition(!PriceRepository.load(url).writable)
        var future = initial
        future.schemaVersion = 99
        try JSONEncoder().encode(future).write(to: url)
        precondition(PriceRepository.load(url).errorKey == "monitor.error.version")
        let blockedDirectory = base.appendingPathComponent("file-not-directory")
        try Data().write(to: blockedDirectory)
        let blocked = PriceMonitorStore(directory: blockedDirectory, loader: OfflinePriceLoader())
        let saved = await blocked.follow(PriceFixtures.result(at: Date()), application: true, purchases: true)
        precondition(!saved && blocked.state.watches.isEmpty && blocked.errorKey == "monitor.error.save")
        let failureDirectory = base.appendingPathComponent("save-failure")
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        var due = PriceMonitoringState()
        due.watches = [PriceWatch(app: PriceFixtures.app)]
        try JSONEncoder().encode(due).write(to: failureDirectory.appendingPathComponent("price-monitoring.json"))
        try FileManager.default.createDirectory(at: failureDirectory.appendingPathComponent("price-monitoring.json.backup"), withIntermediateDirectories: false)
        let counting = CountingPriceLoader()
        let diskFailure = PriceMonitorStore(directory: failureDirectory, loader: counting)
        await diskFailure.refresh(force: true)
        await diskFailure.refresh(force: true)
        let calls = await counting.calls
        precondition(calls == 1 && diskFailure.errorKey == "monitor.error.save",
                     "Failed persistence must not cause an immediate network retry loop")
    }

    @MainActor private static func races() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("AppNotesPriceRace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let loader = HeldPriceLoader()
        let store = PriceMonitorStore(directory: base, loader: loader)
        let oldDate = Date().addingTimeInterval(-300)
        let saved = await store.follow(PriceFixtures.result(at: oldDate), application: true, purchases: true, now: oldDate)
        precondition(saved)
        let check = Task { await store.refresh(force: true) }
        await loader.waitForCall()
        let joined = Task { await store.refresh(force: true) }
        await Task.yield()
        await store.setEnabled(false, watchID: PriceFixtures.app.id)
        await loader.finish(PriceFixtures.result(at: Date(), appPrice: 0, purchasePrice: 0))
        await check.value
        await joined.value
        let calls = await loader.calls
        precondition(calls == 1 && !store.isChecking, "Refreshes must coalesce")
        precondition(store.state.events.isEmpty && store.state.watches[0].products.allSatisfy { $0.candidate == nil })
        precondition(!store.state.watches[0].isEnabled, "Old in-flight response must not restore a paused watch")
        let old = store.state.watches[0]
        await store.setEnabled(true, watchID: old.id)
        let staleEdit = await store.follow(PriceFixtures.result(at: Date()), application: true, purchases: false, replacing: old)
        precondition(!staleEdit && store.errorKey == "monitor.error.changed")
        let current = store.state.watches[0]
        var regional = PriceFixtures.result(at: Date(), appPrice: 0)
        regional.app.country = "us"
        let changed = await store.follow(regional, application: true, purchases: true, replacing: current)
        precondition(changed && store.state.events.isEmpty && store.state.watches[0].app.country == "us")
        let duplicate = await store.follow(PriceFixtures.result(at: Date()), application: true, purchases: false)
        precondition(!duplicate && store.errorKey == "monitor.error.duplicate")
    }
}
