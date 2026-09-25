import Foundation

/// All public Apple catalogue requests share a serial queue and a per-host budget.
enum AppleRequestError: Error { case rateLimited(Date) }

actor AppleRequestQueue {
    static let shared = AppleRequestQueue()
    private var tail: Task<Void, Never>?
    private var nextAllowed: [String: Date] = [:]
    private var retryAfter: [String: Date] = [:]
    private let spacing: TimeInterval

    init(spacing: TimeInterval = 6) { self.spacing = spacing }

    func data(from url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        let previous = tail
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await self.perform(url: url, session: session)
        }
        tail = Task { _ = try? await work.value }
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
        if let value, let date = formatter.date(from: value), date > now { return date }
        return now.addingTimeInterval(60)
    }
}
