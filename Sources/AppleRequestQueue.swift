import Foundation

/// Serialize per host so a slow/cooling storefront never blocks lookup requests.
enum AppleRequestError: Error { case rateLimited(Date) }

actor AppleRequestQueue {
    static let shared = AppleRequestQueue(cooldownURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AppNotes/apple-request-cooldowns.json"))
    private var tails: [String: Task<Void, Never>] = [:]
    private let cooldownURL: URL?
    private var nextAllowed: [String: Date] = [:]
    private var retryAfter: [String: Date] = [:]
    private let spacing: TimeInterval

    init(spacing: TimeInterval = 6, cooldownURL: URL? = nil) {
        self.spacing = spacing
        self.cooldownURL = cooldownURL
        if let cooldownURL, let data = try? Data(contentsOf: cooldownURL),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            retryAfter = saved.filter { $0.value > Date() && $0.value.timeIntervalSinceNow <= 86_400 }
        }
    }

    func data(from url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        let host = url.host ?? ""
        let previous = tails[host]
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await self.perform(url: url, session: session)
        }
        tails[host] = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func perform(url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        let host = url.host ?? ""
        if let retry = retryAfter[host], retry > Date() { throw AppleRequestError.rateLimited(retry) }
        let delay = nextAllowed[host, default: .distantPast].timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        nextAllowed[host] = Date().addingTimeInterval(spacing)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result = try await session.data(for: request)
        if let response = result.1 as? HTTPURLResponse, response.statusCode == 429 {
            let retry = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
            retryAfter[host] = retry
            if let cooldownURL, let data = try? JSONEncoder().encode(retryAfter.filter({ $0.value > Date() })) {
                try? FileManager.default.createDirectory(at: cooldownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cooldownURL, options: .atomic)
            }
        }
        return result
    }

    static func retryDate(_ value: String?, now: Date) -> Date {
        if let value, let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(min(seconds, 86_400))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let value, let date = formatter.date(from: value), date > now { return min(date, now.addingTimeInterval(86_400)) }
        return now.addingTimeInterval(60)
    }
}
