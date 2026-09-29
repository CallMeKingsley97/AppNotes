import Foundation

private final class ReliabilityProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data, headers) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
                httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor GateLoader: PriceLoading {
    var order: [Int64] = []
    var held: [Int64: CheckedContinuation<PriceCheckResult, Error>] = [:]
    func fetch(id: Int64, country: String, expectedBundle: String?) async throws -> PriceCheckResult {
        order.append(id)
        return try await withCheckedThrowingContinuation { held[id] = $0 }
    }
    func wait(_ count: Int) async throws {
        for _ in 0..<500 {
            if order.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for request \(count)")
    }
    func finish(_ app: WatchedApp) {
        held.removeValue(forKey: app.storeID)?.resume(returning: PriceFixtures.result(at: Date(), app: app))
    }
}

private struct PartialPriceLoader: PriceLoading {
    func fetch(id: Int64, country: String, expectedBundle: String?) async throws -> PriceCheckResult {
        var result = PriceFixtures.result(at: Date())
        result.quotes.removeAll { $0.kind == .inAppPurchase }
        result.purchaseCoverageKey = "monitor.coverage.unavailable"
        result.purchaseCount = 0
        result.purchaseIdentityObserved = false
        result.purchaseStatus = PriceSourceStatus(attemptedAt: Date(),
            failure: PriceFetchFailure(issue: .rate, retryAfter: Date().addingTimeInterval(900)))
        return result
    }
}

@main
struct MonitorReliabilityTests {
    @MainActor static func main() async throws {
        assessments()
        try rules()
        try await clientAndBatch()
        try await scheduling()
        try await priorityAndPartial()
        try await hostQueues()
        print("Passed F01–F06: assessment reasons, source status, baseline recovery, request scope, 100-app batching, manual queue/coalescing, cooldown persistence and host isolation.")
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReliabilityProtocol.self]
        return URLSession(configuration: config)
    }

    private static func assessments() {
        let rows = [InAppPurchase(name: "Month", price: "¥8"), InAppPurchase(name: "Life", price: "¥58"),
            InAppPurchase(name: "Pro", price: "¥38"), InAppPurchase(name: " Pro ", price: ""),
            InAppPurchase(name: "7 day trial", price: "Free"), InAppPurchase(name: "No price", price: "0")]
        let checked = PublicPurchasePrices.assess(rows, currency: "CNY")
        precondition(checked.map(\.comparison) == [.comparable, .comparable, .comparable, .missingPrice, .comparable, .missingPrice])
        precondition(checked.count == rows.count)
        precondition(PublicPurchasePrices.assess([rows[0]], currency: "XYZ")[0].comparison == .unsupportedCurrency)
        precondition(PublicPurchasePrices.assess(Array(rows.reversed()), currency: "CNY").map(\.comparison) == checked.reversed().map(\.comparison))
    }

    private static func rules() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var watch = PriceWatch(app: PriceFixtures.app)
        var events: [FreePriceEvent] = []
        func apply(_ seconds: Double, price: Decimal) {
            let date = start.addingTimeInterval(seconds)
            PriceRules.apply(PriceFixtures.result(at: date, purchasePrice: price), to: &watch, events: &events, now: date)
        }
        apply(0, price: 58)
        apply(100, price: 0)
        precondition(watch.products.last?.candidate == nil && events.count == 1)
        PriceRules.failed(PriceFetchFailure(issue: .network), watch: &watch, events: &events, now: start.addingTimeInterval(200))
        precondition(watch.products.last?.paidBaseline?.amount == 58 && watch.products.last?.candidate == nil)
        apply(400, price: 0)
        precondition(events.count == 1 && events[0].status == .free, "Recovery updates the existing offer")
        apply(600, price: 0)
        precondition(events.count == 1 && events[0].previous.amount == 58)

        var disappeared = PriceFixtures.result(at: start.addingTimeInterval(700))
        disappeared.quotes.removeAll { $0.kind == .inAppPurchase }
        PriceRules.apply(disappeared, to: &watch, events: &events, now: start.addingTimeInterval(700))
        precondition(watch.products.last?.paidBaseline == nil && watch.products.last?.episodeID == nil)
        apply(800, price: 0)
        apply(1000, price: 0)
        precondition(events.count == 2 && events[1].status == .free, "Reappearing zero price starts an offer")

        apply(1100, price: 58)
        PriceRules.failed(PriceFetchFailure(issue: .network), watch: &watch, events: &events,
            now: start.addingTimeInterval(PriceRules.baselineLifetime + 1200))
        precondition(watch.products.last?.paidBaseline == nil)

        let now = Date()
        var partial = PriceFixtures.result(at: now)
        partial.quotes.removeAll { $0.kind == .inAppPurchase }
        partial.purchaseCoverageKey = "monitor.coverage.unavailable"
        partial.purchaseIdentityObserved = false
        let until = now.addingTimeInterval(4000)
        partial.purchaseStatus = PriceSourceStatus(attemptedAt: now, failure: PriceFetchFailure(issue: .rate, retryAfter: until))
        var other = PriceWatch(app: partial.app)
        var none: [FreePriceEvent] = []
        PriceRules.apply(partial, to: &other, events: &none, now: now)
        precondition(other.applicationStatus?.succeeded == true && other.purchaseStatus?.failure?.issue == .rate)
        precondition(other.nextCheck >= until && other.lastSuccess == nil)
        let restored = try JSONDecoder().decode(PriceWatch.self, from: JSONEncoder().encode(other))
        precondition(restored.retryAfter == until)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(other)) as! [String: Any]
        raw.removeValue(forKey: "applicationStatus")
        raw.removeValue(forKey: "purchaseStatus")
        _ = try JSONDecoder().decode(PriceWatch.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    private static func clientAndBatch() async throws {
        let client = AppStorePriceClient(session: session(), queue: AppleRequestQueue(spacing: 0))
        var lookupCalls = 0
        var pageCalls = 0
        ReliabilityProtocol.handler = { request in
            let url = request.url!
            if url.host == "itunes.apple.com" {
                lookupCalls += 1
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                let ids = query.first { $0.name == "id" }!.value!.split(separator: ",").map { Int64($0)! }
                precondition(ids.count <= 10)
                let records: [[String: Any]] = ids.reversed().map { id in
                    ["trackId": id, "wrapperType": "software", "bundleId": "test.\(id)", "trackName": "App \(id)",
                     "kind": "mac-software", "price": 28, "currency": "CNY"]
                }
                return (200, try JSONSerialization.data(withJSONObject: ["results": records]), [:])
            }
            pageCalls += 1
            let id = Int64(url.lastPathComponent.dropFirst(2))!
            let app = AppEntry(path: "/test/\(id)", name: "App \(id)", bundleID: "test.\(id)", version: nil,
                appStoreID: id, storefrontCountryCode: "cn")
            return (200, Data(try DetailsFixtures.pageHTML(listing: DetailsFixtures.listing(for: app)).utf8), [:])
        }
        let requests = (1...100).map { PriceRequest(id: Int64($0), country: "cn", expectedBundle: "test.\($0)", purchases: $0 <= 10) }
        let base = await client.lookup(requests)
        precondition(base.count == 100 && lookupCalls == 10)
        for request in requests {
            let result = try await client.complete(request, lookup: base[request.key]!.get())
            precondition(result.app.storeID == request.id)
            precondition(request.purchases ? result.purchaseSnapshot?.purchases.count == 4 : result.purchaseSnapshot == nil)
        }
        precondition(pageCalls == 10, "Only watched purchases should fetch HTML")

        let request = requests[0]
        let listing = try DetailsFixtures.listing(for: AppEntry(path: "/test/1", name: "App 1", bundleID: "test.1", version: nil, appStoreID: 1, storefrontCountryCode: "cn"))
        for (status, html, issue) in [
            (429, "", PriceFetchIssue.rate),
            (503, "", .response),
            (200, "<html></html>", .pageFormat),
            (200, "<script id=\"serialized-server-data\">{broken</script>", .pageFormat),
            (200, try DetailsFixtures.pageHTML(listing: listing, language: "en"), .pageIdentity),
            (200, try DetailsFixtures.pageHTML(listing: listing, purchases: true, includeList: false), .purchases)
        ] {
            ReliabilityProtocol.handler = { _ in (status, Data(html.utf8), ["Retry-After": "600"]) }
            let isolated = AppStorePriceClient(session: session(), queue: AppleRequestQueue(spacing: 0))
            let result = try await isolated.complete(request, lookup: base[request.key]!.get())
            precondition(result.applicationAvailable && result.purchaseStatus?.failure?.issue == issue)
            precondition(!result.purchaseIdentityObserved && result.purchaseSnapshot == nil)
        }
        // A missing batch entry is not guessed or matched by index.
        ReliabilityProtocol.handler = { _ in (200, Data(#"{"results":[]}"#.utf8), [:]) }
        let missing = await client.lookup([request])
        precondition(missing.isEmpty)
    }

    @MainActor private static func scheduling() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("AppNotesReliability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let loader = GateLoader()
        let store = PriceMonitorStore(directory: base, loader: loader)
        var a = PriceFixtures.app
        a.storeID = 1001
        var b = a
        b.storeID = 1002
        let old = Date().addingTimeInterval(-600)
        for app in [a, b] {
            let saved = await store.follow(PriceFixtures.result(at: old, app: app), application: true, purchases: false, now: old)
            precondition(saved)
        }
        await store.setAutomaticChecks(false)
        let first = Task { await store.refresh(watchID: a.id, force: true) }
        try await loader.wait(1)
        let joined = Task { await store.refresh(watchID: a.id, force: true) }
        let second = Task { await store.refresh(watchID: b.id, force: true) }
        for _ in 0..<10 { await Task.yield() }
        await loader.finish(a)
        try await loader.wait(2)
        await loader.finish(b)
        let reports = await [first.value, joined.value, second.value]
        precondition(reports.allSatisfy { $0.disposition == .updated })
        let order = await loader.order
        precondition(order == [a.storeID, b.storeID], "Join same target, do not lose a different target")
        precondition(!store.isChecking && !store.state.automaticChecks)
        let cooldown = await store.refresh(watchID: a.id, force: true)
        precondition(cooldown.disposition == .waiting && cooldown.retryAfter != nil)
        let calls = await loader.order.count
        precondition(calls == 2)
        let reload = PriceMonitorStore(directory: base, loader: loader)
        let afterRestart = await reload.refresh(watchID: a.id, force: true)
        precondition(afterRestart.disposition == .waiting)
    }

    @MainActor private static func priorityAndPartial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppNotesPriority-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-600)
        var state = PriceMonitoringState()
        for id in 1...3 {
            var app = PriceFixtures.app
            app.storeID = Int64(id)
            var watch = PriceWatch(app: app)
            watch.lastAttempt = old
            watch.nextCheck = old
            if id == 2 {
                watch.products = [ProductPriceState(id: "app", kind: .application, name: app.name,
                    candidate: PriceCandidate(isFree: true, firstObservedAt: old))]
            }
            state.watches.append(watch)
        }
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("price-monitoring.json"))
        let loader = GateLoader()
        let store = PriceMonitorStore(directory: directory, loader: loader)
        let all = Task { await store.refresh(force: true) }
        try await loader.wait(1)
        let initial = await loader.order
        precondition(initial == [2], "Due confirmation precedes routine targets")
        let manual = Task { await store.refresh(watchID: state.watches[2].id, force: true) }
        for _ in 0..<10 { await Task.yield() }
        await loader.finish(state.watches[1].app)
        try await loader.wait(2)
        let priority = await loader.order
        precondition(priority == [2, 3], "A selected manual target precedes the remaining routine target")
        await loader.finish(state.watches[2].app)
        try await loader.wait(3)
        await loader.finish(state.watches[0].app)
        _ = await all.value
        _ = await manual.value

        let partialDirectory = directory.appendingPathComponent("partial")
        let partialStore = PriceMonitorStore(directory: partialDirectory, loader: PartialPriceLoader())
        let saved = await partialStore.follow(PriceFixtures.result(at: old), application: true, purchases: true, now: old)
        precondition(saved)
        let report = await partialStore.refresh(force: true)
        precondition(report.disposition == .partial)
        let updated = partialStore.state.watches[0]
        precondition(updated.applicationStatus?.succeeded == true && updated.purchaseStatus?.failure?.issue == .rate)
        precondition(updated.products.last?.paidBaseline != nil)
        let rate = await partialStore.refresh(force: true)
        precondition(rate.disposition == .waiting && rate.retryAfter!.timeIntervalSinceNow > 800)
        let restarted = PriceMonitorStore(directory: partialDirectory, loader: PartialPriceLoader())
        let resumed = await restarted.refresh(force: true)
        precondition(resumed.disposition == .waiting && resumed.retryAfter!.timeIntervalSinceNow > 800)
    }

    private static func hostQueues() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("AppNotesCooldown-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("cooldowns.json")
        let queue = AppleRequestQueue(spacing: 0, cooldownURL: url)
        let network = session()
        ReliabilityProtocol.handler = { _ in (429, Data(), ["Retry-After": "600"]) }
        _ = try await queue.data(from: URL(string: "https://apps.apple.com/test")!, session: network)
        let restored = AppleRequestQueue(spacing: 0, cooldownURL: url)
        ReliabilityProtocol.handler = { request in
            precondition(request.url!.host == "itunes.apple.com", "Persisted cooldown must prevent storefront requests")
            return (200, Data("ok".utf8), [:])
        }
        do {
            _ = try await restored.data(from: URL(string: "https://apps.apple.com/test")!, session: network)
            preconditionFailure("Expected persisted cooldown")
        } catch AppleRequestError.rateLimited(let retry) { precondition(retry.timeIntervalSinceNow > 500) }
        _ = try await restored.data(from: URL(string: "https://itunes.apple.com/test")!, session: network)

        // A host waiting for its spacing must not hold up a different host.
        let spaced = AppleRequestQueue(spacing: 2)
        ReliabilityProtocol.handler = { _ in (200, Data(), [:]) }
        _ = try await spaced.data(from: URL(string: "https://apps.apple.com/a")!, session: network)
        let delayed = Task { try await spaced.data(from: URL(string: "https://apps.apple.com/b")!, session: network) }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        _ = try await spaced.data(from: URL(string: "https://itunes.apple.com/a")!, session: network)
        precondition(Date().timeIntervalSince(start) < 1.5, "Different hosts must not share a sleeping tail")
        delayed.cancel()
        _ = try? await delayed.value
    }
}
