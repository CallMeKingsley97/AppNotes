import Foundation

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private actor CountingLoader: AppDetailsLoading {
    var calls = 0
    var fail = false
    var delay = false
    func setFailure(_ value: Bool) { fail = value }
    func setDelay(_ value: Bool) { delay = value }
    func fetch(app: AppEntry, country: String, language: String) async throws -> AppDetails {
        calls += 1
        if delay { try await Task.sleep(for: .seconds(5)) }
        if fail { throw URLError(.notConnectedToInternet) }
        return try DetailsFixtures.details(app: app, country: country, language: language)
    }
}

@main
struct AppDetailsTests {
    @MainActor static func main() async throws {
        let app = DetailsFixtures.app
        let listing = try DetailsFixtures.listing()
        precondition(listing.matches(app))
        let wrongBundle = AppEntry(path: app.path, name: app.name, bundleID: "com.someone.else",
                                   version: nil, appStoreID: app.appStoreID, storefrontCountryCode: "cn")
        precondition(!listing.matches(wrongBundle))
        let bundleOnly = AppEntry(path: app.path, name: app.name, bundleID: app.bundleID,
                                  version: nil, appStoreID: nil, storefrontCountryCode: "cn")
        precondition(listing.matches(bundleOnly))
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(listing)) as! [String: Any]
        raw["kind"] = "software"
        let ios = try JSONDecoder().decode(StoreListing.self, from: JSONSerialization.data(withJSONObject: raw))
        precondition(!ios.matches(bundleOnly))
        let longDescription = String(repeating: "完整介绍，不应被截断。\n", count: 300)
        raw["description"] = longDescription
        let long = try JSONDecoder().decode(StoreListing.self, from: JSONSerialization.data(withJSONObject: raw))
        precondition(long.description == longDescription)
        for language in ["zh-Hans", "en"] {
            let html = try DetailsFixtures.pageHTML(listing: listing, language: language)
            let page = try StorePageDetails.parse(html, listing: listing, country: "cn")
            precondition(page.purchases.count == 4)
            precondition(page.purchases[2].name == page.purchases[3].name)
            precondition(page.purchases[2].price != page.purchases[3].price)
            precondition(page.requirements.first?.platform == "Mac")
            let none = try StorePageDetails.parse(DetailsFixtures.pageHTML(listing: listing, purchases: false), listing: listing, country: "cn")
            precondition(none.hasInAppPurchases == false && none.purchases.isEmpty)
            let unknown = try StorePageDetails.parse(DetailsFixtures.pageHTML(listing: listing, purchases: nil), listing: listing, country: "cn")
            precondition(unknown.hasInAppPurchases == nil && unknown.purchases.isEmpty)
            do {
                _ = try StorePageDetails.parse(html.replacingOccurrences(of: listing.bundleId!, with: "unrelated.bundle"), listing: listing, country: "cn")
                preconditionFailure("Mismatched product page must be rejected")
            } catch AppDetailsError.invalidPage {}
            do {
                _ = try StorePageDetails.parse(html, listing: listing, country: "us")
                preconditionFailure("Redirected storefront prices must not be mislabeled")
            } catch AppDetailsError.invalidPage {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = AppStoreDetailsClient(session: URLSession(configuration: config))
        let lookupData = try JSONEncoder().encode(["results": [listing]])
        let htmlData = Data(try DetailsFixtures.pageHTML(listing: listing).utf8)
        StubURLProtocol.handler = { request in
            let url = request.url!
            if url.host == "itunes.apple.com" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(query.contains(URLQueryItem(name: "id", value: String(app.appStoreID!))))
                return (200, lookupData)
            }
            precondition(url.host == "apps.apple.com" && url.path == "/cn/app/id\(listing.trackId)")
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .contains(URLQueryItem(name: "platform", value: "mac")))
            return (200, htmlData)
        }
        let fetched = try await client.fetch(app: app, country: "cn", language: "zh-Hans")
        precondition(fetched.country == "cn" && fetched.page?.purchases.count == 4)
        StubURLProtocol.handler = { request in
            request.url!.host == "itunes.apple.com" ? (200, lookupData) : (503, Data())
        }
        let partial = try await client.fetch(app: app, country: "cn", language: "zh-Hans")
        precondition(partial.listing.description == listing.description && partial.page == nil)
        StubURLProtocol.handler = { _ in (200, Data(#"{"results":[]}"#.utf8)) }
        do {
            _ = try await client.fetch(app: app, country: "cn", language: "en")
            preconditionFailure("Empty regional lookups must not invent a match")
        } catch AppDetailsError.notFound {}
        StubURLProtocol.handler = { _ in (429, Data()) }
        do {
            _ = try await client.fetch(app: app, country: "cn", language: "en")
            preconditionFailure("HTTP errors must not be interpreted as no purchases")
        } catch AppDetailsError.invalidResponse {}
        precondition(URL.web("javascript:alert(1)") == nil && URL.web("file:///etc/hosts") == nil)
        precondition(URL.web("https://example.com") != nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppNotesDetailsTests-\(UUID().uuidString)")
        let loader = CountingLoader()
        var cacheTime = Date()
        let store = AppDetailsStore(directory: directory, loader: loader, now: { cacheTime })
        await store.load(app: app, language: "zh-Hans")
        await store.load(app: app, language: "zh-Hans")
        let initialCalls = await loader.calls
        precondition(initialCalls == 1)
        await store.load(app: app, language: "en")
        let languageCalls = await loader.calls
        precondition(languageCalls == 2)
        cacheTime = cacheTime.addingTimeInterval(86_401)
        await store.load(app: app, language: "zh-Hans")
        let expiredCalls = await loader.calls
        precondition(expiredCalls == 3, "A successful lookup must not block refresh after cache expiry")
        precondition(store.details(for: wrongBundle, language: "zh-Hans") == nil)
        let saved = store.details(for: app, language: "zh-Hans")!
        await loader.setFailure(true)
        await store.load(app: app, language: "zh-Hans", force: true)
        precondition(store.details(for: app, language: "zh-Hans") == saved)
        precondition(store.errors[AppDetailsStore.key(for: app, language: "zh-Hans")] == "info.loadFailed")
        store.flush()
        let restored = AppDetailsStore(directory: directory, loader: loader)
        precondition(restored.details(for: app, language: "zh-Hans") == saved)
        precondition(restored.details(for: app, language: "en") != nil)
        await loader.setFailure(false)
        await loader.setDelay(true)
        let task = Task { await store.load(app: app, language: "en", force: true) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        precondition(store.loading.isEmpty && store.errors[AppDetailsStore.key(for: app, language: "en")] == nil)
        await loader.setDelay(false)
        await store.load(app: app, language: "en", force: true)
        precondition(store.details(for: app, language: "en") != nil)
        print("Passed: exact identity matching, full descriptions, bilingual page parsing, purchase availability, region consistency, HTTP failures, cancellation, cache expiry, and persistent cache fallback.")

        if CommandLine.arguments.contains("--live") {
            let live = AppStoreDetailsClient()
            for app in [
                AppEntry(path: "/test/ApiCatcher.app", name: "ApiCatcher", bundleID: "com.wujiuye.ApiCatcher",
                         version: nil, appStoreID: 6757103562, storefrontCountryCode: "cn"),
                AppEntry(path: "/test/Xcode.app", name: "Xcode", bundleID: "com.apple.dt.Xcode",
                         version: nil, appStoreID: 497799835, storefrontCountryCode: "cn")
            ] {
                let result = try await live.fetch(app: app, country: app.storefrontCountryCode!, language: "zh-Hans")
                precondition(result.listing.matches(app))
                precondition(result.listing.description?.isEmpty == false)
                print("Live \(app.name): country=\(result.country), kind=\(result.listing.kind ?? ""), description=\(result.listing.description!.count) characters, purchases=\(result.page?.purchases.count.description ?? "unavailable"), compatibility=\(result.page?.requirements.count.description ?? "unavailable")")
            }
        }
    }
}
