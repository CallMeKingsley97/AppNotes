import AppKit
import Foundation

enum PriceStorageError: Error { case unavailable, limit, duplicate, changed, invalidScope }

actor PriceRepository {
    struct Loaded { var state: PriceMonitoringState; var errorKey: String?; var writable: Bool }
    private var state: PriceMonitoringState
    private let url: URL
    private let writable: Bool
    private var sequence = 0

    init(url: URL, loaded: Loaded) {
        self.url = url
        state = loaded.state
        writable = loaded.writable
    }

    static func load(_ url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Loaded(state: PriceMonitoringState(), writable: true)
        }
        do {
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(PriceMonitoringState.self, from: data)
            guard state.schemaVersion == 1 else {
                return Loaded(state: PriceMonitoringState(), errorKey: "monitor.error.version", writable: false)
            }
            return Loaded(state: state, writable: true)
        } catch {
            if let data = try? Data(contentsOf: url.appendingPathExtension("backup")),
               let state = try? JSONDecoder().decode(PriceMonitoringState.self, from: data), state.schemaVersion == 1 {
                return Loaded(state: state, errorKey: "monitor.error.recovered", writable: true)
            }
            return Loaded(state: PriceMonitoringState(), errorKey: "monitor.error.load", writable: false)
        }
    }

    func update(_ change: @Sendable (inout PriceMonitoringState) throws -> Void) throws -> (state: PriceMonitoringState, sequence: Int) {
        guard writable else { throw PriceStorageError.unavailable }
        var next = state
        try change(&next)
        guard next != state else { return (state, sequence) }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Preserve the committed state, never copy a corrupt primary over a valid backup.
        try JSONEncoder().encode(state).write(to: url.appendingPathExtension("backup"), options: .atomic)
        try data.write(to: url, options: .atomic)
        state = next
        sequence += 1
        return (state, sequence)
    }
}

@MainActor
final class PriceMonitorStore: ObservableObject {
    static let shared = PriceMonitorStore()
    static let didChange = Notification.Name("AppNotes.priceMonitoringDidChange")
    @Published private(set) var state: PriceMonitoringState
    @Published private(set) var isChecking = false
    @Published private(set) var progress = 0
    @Published private(set) var total = 0
    @Published private(set) var refreshReport: PriceRefreshReport?
    @Published private(set) var watchReports: [String: PriceRefreshReport] = [:]
    @Published private(set) var activeWatchID: String?
    private var pending: [PriceWatch] = []
    private var manualTargets: Set<String> = []
    private var activeRevision: UUID?
    private var isFinishingPass = false
    private var passReports: [String: PriceRefreshReport] = [:]
    @Published var errorKey: String?
    @Published private(set) var undoMessageKey: String?
    let writable: Bool
    private let repository: PriceRepository
    private let loader: any PriceLoading
    private var checkTask: Task<[String: PriceRefreshReport], Never>?
    private var verificationTask: Task<Void, Never>?
    private var scheduler: NSBackgroundActivityScheduler?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private var appliedSequence = 0
    private var storageRetryAfter = Date.distantPast
    private var undoChange: (@Sendable (inout PriceMonitoringState) -> Void)?

    init(directory: URL? = nil, loader: any PriceLoading = AppStorePriceClient()) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppNotes", isDirectory: true)
        let url = base.appendingPathComponent("price-monitoring.json")
        let loaded = PriceRepository.load(url)
        state = loaded.state
        writable = loaded.writable
        errorKey = loaded.errorKey
        repository = PriceRepository(url: url, loaded: loaded)
        self.loader = loader
    }

    var unreadCount: Int { state.events.filter(\.isUnread).count }
    var sortedEvents: [FreePriceEvent] {
        state.events.sorted {
            $0.discoveredAt == $1.discoveredAt ? $0.id.uuidString < $1.id.uuidString : $0.discoveredAt > $1.discoveredAt
        }
    }
    func watch(for id: String) -> PriceWatch? { state.watches.first { $0.id == id } }

    func inspect(id: Int64, country: String, bundle: String? = nil, purchases: Bool = true) async throws -> PriceCheckResult {
        try await loader.fetch(PriceRequest(id: id, country: country, expectedBundle: bundle, purchases: purchases))
    }

    @discardableResult
    func follow(_ result: PriceCheckResult, application: Bool, purchases: Bool,
                replacing old: PriceWatch? = nil, now: Date = Date()) async -> Bool {
        let saved = await commit { snapshot in
            guard application || purchases else { throw PriceStorageError.invalidScope }
            if let old {
                guard snapshot.watches.contains(where: { $0.id == old.id && $0.revision == old.revision }) else {
                    throw PriceStorageError.changed
                }
            }
            guard !snapshot.watches.contains(where: { $0.app.storeID == result.app.storeID && $0.id != old?.id }) else {
                throw PriceStorageError.duplicate
            }
            guard old != nil || snapshot.watches.count < 100 else { throw PriceStorageError.limit }
            var watch = snapshot.watches.first(where: { $0.id == old?.id && $0.id == result.app.id }) ?? PriceWatch(app: result.app)
            watch.revision = UUID()
            watch.watchesApplication = application
            watch.watchesPurchases = purchases
            if let old, old.id != result.app.id {
                for index in snapshot.events.indices where snapshot.events[index].app.id == old.id && snapshot.events[index].status != .ended {
                    snapshot.events[index].status = .unavailable
                }
            }
            // Attach a retained free episode when re-following an app; never replay its notification.
            if old == nil {
                for quote in result.quotes {
                    if let event = snapshot.events.last(where: {
                        $0.app.id == result.app.id && $0.productID == quote.id && $0.status != .ended
                    }) {
                        watch.products.append(ProductPriceState(id: quote.id, kind: quote.kind, name: quote.name,
                                                               episodeID: event.id))
                    }
                }
            }
            PriceRules.apply(result, to: &watch, events: &snapshot.events, now: now)
            snapshot.watches.removeAll { $0.id == old?.id }
            snapshot.watches.append(watch)
        }
        if saved { armVerification() }
        return saved
    }

    func setEnabled(_ enabled: Bool, watchID: String) async {
        if await commit({ snapshot in
            guard let index = snapshot.watches.firstIndex(where: { $0.id == watchID }) else { return }
            snapshot.watches[index].isEnabled = enabled
            snapshot.watches[index].revision = UUID()
            snapshot.watches[index].nextCheck = .distantPast
            for product in snapshot.watches[index].products.indices {
                snapshot.watches[index].products[product].candidate = nil
                snapshot.watches[index].products[product].paidBaseline = nil
            }
        }) { armVerification() }
    }

    func remove(watchID: String) async {
        guard let watch = watch(for: watchID) else { return }
        if await commit({ $0.watches.removeAll { $0.id == watchID } }) {
            undoMessageKey = "monitor.undo.unfollow"
            undoChange = { snapshot in
                guard snapshot.watches.count < 100, !snapshot.watches.contains(where: { $0.app.storeID == watch.app.storeID }) else { return }
                var restored = watch
                restored.revision = UUID()
                restored.nextCheck = .distantPast
                snapshot.watches.append(restored)
            }
            armVerification()
        }
    }

    func setAutomaticChecks(_ enabled: Bool) async {
        if await commit({ $0.automaticChecks = enabled }) {
            if !enabled { checkTask?.cancel() }
            configureScheduler()
            armVerification()
        }
    }

    func markRead(_ ids: Set<UUID>, read: Bool, undoable: Bool = false) async {
        let previous = state.events.filter { ids.contains($0.id) }.map { ($0.id, $0.readAt) }
        let now = Date()
        if await commit({ snapshot in
            for index in snapshot.events.indices where ids.contains(snapshot.events[index].id) {
                snapshot.events[index].readAt = read ? (snapshot.events[index].readAt ?? now) : nil
            }
        }), undoable {
            undoMessageKey = "monitor.undo.read"
            undoChange = { snapshot in
                for (id, date) in previous {
                    if let index = snapshot.events.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) {
                        snapshot.events[index].readAt = date
                    }
                }
            }
        }
    }

    func archive(_ id: UUID, archived: Bool) async {
        guard let previous = state.events.first(where: { $0.id == id }) else { return }
        let now = Date()
        if await commit({ snapshot in
            guard let index = snapshot.events.firstIndex(where: { $0.id == id }) else { return }
            snapshot.events[index].archivedAt = archived ? now : nil
            if archived { snapshot.events[index].readAt = snapshot.events[index].readAt ?? now }
        }) {
            undoMessageKey = "monitor.undo.archive"
            undoChange = { snapshot in
                guard let index = snapshot.events.firstIndex(where: { $0.id == id }) else { return }
                snapshot.events[index].archivedAt = previous.archivedAt
                snapshot.events[index].readAt = previous.readAt
            }
        }
    }

    func undo() async {
        guard let change = undoChange else { return }
        if await commit(change) { undoChange = nil; undoMessageKey = nil; armVerification() }
    }

    func start() {
        guard !started else { return }
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.checkIfDue() } }
        configureScheduler()
        Task { await checkIfDue() }
    }

    func stop() {
        started = false
        scheduler?.invalidate()
        scheduler = nil
        checkTask?.cancel()
        verificationTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func checkIfDue() async {
        guard started, state.automaticChecks else { return }
        await refresh()
    }

    @discardableResult
    func refresh(watchID: String? = nil, force: Bool = false) async -> PriceRefreshReport {
        if isFinishingPass, let running = checkTask {
            _ = await running.value
            return await refresh(watchID: watchID, force: force)
        }
        let now = Date()
        guard writable, now >= storageRetryAfter else {
            let report = PriceRefreshReport(disposition: .failed, retryAfter: storageRetryAfter > now ? storageRetryAfter : nil)
            publish(report, watchID: watchID, manual: force)
            return report
        }
        let selected = state.watches.filter { $0.isEnabled && (watchID == nil || $0.id == watchID) }
        var targets: [PriceWatch] = []
        var waits: [Date] = []
        for watch in selected {
            let alreadyQueued = pending.contains { $0.id == watch.id && $0.revision == watch.revision }
                || (activeWatchID == watch.id && activeRevision == watch.revision)
            let allowed = max(watch.lastAttempt?.addingTimeInterval(60) ?? .distantPast,
                watch.retryAfter ?? (watch.errorKey == "monitor.error.rate" ? watch.nextCheck : .distantPast))
            if alreadyQueued || (force ? now >= allowed : now >= max(watch.nextCheck, allowed)) {
                targets.append(watch)
            } else if force {
                waits.append(allowed)
                watchReports[watch.id] = PriceRefreshReport(disposition: .waiting, waiting: 1, retryAfter: allowed)
            }
        }
        guard !targets.isEmpty else {
            let report = PriceRefreshReport(disposition: waits.isEmpty ? .skipped : .waiting,
                waiting: waits.count, retryAfter: waits.min())
            publish(report, watchID: watchID, manual: force)
            armVerification()
            return report
        }
        if checkTask == nil {
            progress = 0
            total = 0
            passReports = [:]
        }
        for target in targets {
            if force && watchID != nil { manualTargets.insert(target.id) }
            if !(activeWatchID == target.id && activeRevision == target.revision),
               !pending.contains(where: { $0.id == target.id && $0.revision == target.revision }) {
                pending.removeAll { $0.id == target.id }
                pending.append(target)
                total += 1
            }
            if force { watchReports[target.id] = PriceRefreshReport(disposition: .queued) }
        }
        publish(PriceRefreshReport(disposition: .queued), watchID: watchID, manual: force)
        if checkTask == nil {
            isChecking = true
            checkTask = Task { [weak self] in await self?.runChecks() ?? [:] }
        }
        let work = checkTask!
        let completedReports = await work.value
        let reports = targets.compactMap { completedReports[$0.id] }
        let successes = reports.filter { $0.disposition == .updated }.count
        let checked = reports.reduce(0) { $0 + $1.checked }
        let disposition: PriceRefreshReport.Disposition
        if reports.contains(where: { $0.disposition == .cancelled }) { disposition = .cancelled }
        else if successes == targets.count && waits.isEmpty { disposition = .updated }
        else if successes > 0 || reports.contains(where: { $0.disposition == .partial }) { disposition = .partial }
        else { disposition = .failed }
        let report = PriceRefreshReport(disposition: disposition, checked: checked, waiting: waits.count,
            retryAfter: (waits + reports.compactMap(\.retryAfter)).min())
        publish(report, watchID: watchID, manual: force)
        return report
    }

    private func publish(_ report: PriceRefreshReport, watchID: String?, manual: Bool) {
        guard manual else { return }
        refreshReport = report
        if let watchID { watchReports[watchID] = report }
    }

    private func prioritize() {
        pending.sort {
            let left = manualTargets.contains($0.id), right = manualTargets.contains($1.id)
            if left != right { return left }
            let lc = $0.products.contains { $0.candidate != nil }
            let rc = $1.products.contains { $0.candidate != nil }
            if lc != rc { return lc }
            return $0.nextCheck == $1.nextCheck ? $0.id < $1.id : $0.nextCheck < $1.nextCheck
        }
    }

    private func runChecks() async -> [String: PriceRefreshReport] {
        var prepared: [String: Result<PriceCheckResult, PriceFetchFailure>] = [:]
        var preparedIDs: Set<String> = []
        var attempts: [String: Int] = [:]
        defer {
            for target in pending { passReports[target.id] = PriceRefreshReport(disposition: .cancelled) }
            pending = []
            manualTargets = []
            activeWatchID = nil
            activeRevision = nil
            checkTask = nil
            isFinishingPass = false
            isChecking = false
            armVerification()
        }
        while !pending.isEmpty {
            guard !Task.isCancelled, Date() >= storageRetryAfter else { break }
            // Confirmations that become due during a long pass join before remaining routine work.
            if started && state.automaticChecks {
                for watch in state.watches where watch.isEnabled && watch.nextCheck <= Date()
                    && watch.products.contains(where: { $0.candidate != nil }) && attempts[watch.id, default: 0] < 2
                    && !pending.contains(where: { $0.id == watch.id }) {
                    pending.append(watch)
                    prepared.removeValue(forKey: watch.id)
                    preparedIDs.remove(watch.id)
                    total += 1
                }
            }
            prioritize()
            if let first = pending.first, !preparedIDs.contains(first.id) {
                let batch = Array(pending.filter { $0.app.country == first.app.country && !preparedIDs.contains($0.id) }.prefix(10))
                let lookups = await loader.lookup(batch.map(\.request))
                prepared.merge(lookups) { _, new in new }
                preparedIDs.formUnion(batch.map(\.id))
                guard !Task.isCancelled else { break }
                // A user request may have arrived during the lookup. Reconsider priorities before taking a target.
                prioritize()
            }
            let target = pending.removeFirst()
            guard let current = watch(for: target.id), current.revision == target.revision, current.isEnabled else {
                passReports[target.id] = PriceRefreshReport(disposition: .cancelled)
                progress += 1
                continue
            }
            activeWatchID = target.id
            activeRevision = target.revision
            attempts[target.id, default: 0] += 1
            var report: PriceRefreshReport
            do {
                let result: PriceCheckResult
                if let cached = prepared.removeValue(forKey: target.id) {
                    result = try await loader.complete(target.request, lookup: cached.get())
                } else { result = try await loader.fetch(target.request) }
                try Task.checkCancellation()
                let now = Date()
                let saved = await commit { snapshot in
                    guard let index = snapshot.watches.firstIndex(where: { $0.id == target.id && $0.revision == target.revision && $0.isEnabled }) else { return }
                    PriceRules.apply(result, to: &snapshot.watches[index], events: &snapshot.events, now: now)
                }
                if !saved { report = PriceRefreshReport(disposition: .failed) }
                else if watch(for: target.id)?.revision != target.revision { report = PriceRefreshReport(disposition: .cancelled) }
                else {
                    let appOK = !target.watchesApplication || result.applicationAvailable
                    let purchaseOK = !target.watchesPurchases ||
                        (result.purchaseStatus?.succeeded ?? (result.purchaseCoverageKey != "monitor.coverage.unavailable"))
                    report = PriceRefreshReport(disposition: appOK && purchaseOK ? .updated :
                        ((target.watchesApplication && result.applicationAvailable) || (target.watchesPurchases && purchaseOK) ? .partial : .failed),
                        checked: 1, retryAfter: watch(for: target.id)?.retryAfter)
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    passReports[target.id] = PriceRefreshReport(disposition: .cancelled)
                    break
                }
                let failure = AppStorePriceClient.failure(error)
                let now = Date()
                _ = await commit { snapshot in
                    guard let index = snapshot.watches.firstIndex(where: { $0.id == target.id && $0.revision == target.revision }) else { return }
                    PriceRules.failed(failure, watch: &snapshot.watches[index], events: &snapshot.events, now: now)
                    // Bounded jitter avoids synchronized retry storms across installations.
                    if failure.retryAfter == nil {
                        snapshot.watches[index].nextCheck += Double.random(in: 0...30)
                    }
                }
                report = PriceRefreshReport(disposition: .failed, checked: 1, retryAfter: failure.retryAfter)
            }
            passReports[target.id] = report
            watchReports[target.id] = report
            activeWatchID = nil
            activeRevision = nil
            manualTargets.remove(target.id)
            progress += 1
        }
        isFinishingPass = true
        let enabled = state.watches.filter(\.isEnabled)
        if !Task.isCancelled, !enabled.isEmpty, enabled.allSatisfy({ passReports[$0.id]?.disposition == .updated }) {
            let now = Date()
            _ = await commit { snapshot in
                snapshot.lastCompleteCheck = now
                snapshot.events.removeAll { $0.readAt != nil && $0.endedAt.map { now.timeIntervalSince($0) > 90 * 86_400 } == true }
            }
        }
        for target in pending { passReports[target.id] = PriceRefreshReport(disposition: .cancelled) }
        return passReports
    }

    private func configureScheduler() {
        scheduler?.invalidate()
        scheduler = nil
        guard started, writable, state.automaticChecks, state.watches.contains(where: \.isEnabled) else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.workbuddy.appnotes.price-monitor")
        scheduler.interval = PriceRules.interval
        scheduler.tolerance = 900
        scheduler.repeats = true
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.checkIfDue()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    private func armVerification() {
        verificationTask?.cancel()
        verificationTask = nil
        guard started, writable, state.automaticChecks else { return }
        if scheduler == nil { configureScheduler() }
        let active = state.watches.filter(\.isEnabled)
        guard !active.isEmpty else { configureScheduler(); return }
        // Short one-shot tasks only for initial checks, confirmation and failed requests.
        let soon = active.filter { $0.nextCheck.timeIntervalSinceNow < PriceRules.interval - 60 }.map(\.nextCheck).min()
        guard let soon else { return }
        let delay = max(1, max(soon, storageRetryAfter).timeIntervalSinceNow)
        verificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.checkIfDue()
        }
    }

    @discardableResult
    private func commit(_ change: @escaping @Sendable (inout PriceMonitoringState) throws -> Void) async -> Bool {
        do {
            let committed = try await repository.update(change)
            guard committed.sequence >= appliedSequence else { return true }
            if committed.sequence > appliedSequence { storageRetryAfter = .distantPast }
            appliedSequence = committed.sequence
            state = committed.state
            errorKey = nil
            NotificationCenter.default.post(name: Self.didChange, object: self)
            return true
        } catch {
            switch error {
            case PriceStorageError.limit: errorKey = "monitor.error.limit"
            case PriceStorageError.duplicate: errorKey = "monitor.error.duplicate"
            case PriceStorageError.changed: errorKey = "monitor.error.changed"
            case PriceStorageError.invalidScope: errorKey = "monitor.error.scope"
            case PriceStorageError.unavailable: errorKey = "monitor.error.load"
            default:
                errorKey = "monitor.error.save"
                storageRetryAfter = Date().addingTimeInterval(300)
            }
            return false
        }
    }
}

@MainActor
final class MonitorNavigation: ObservableObject {
    static let shared = MonitorNavigation()
    struct Request: Equatable { var id = UUID(); var page: String; var eventID: UUID?; var watchID: String? = nil }
    @Published var request: Request?
    func showReminders(_ eventID: UUID? = nil) { request = Request(page: "monitor:reminders", eventID: eventID) }
    func showWatches(_ watchID: String? = nil) { request = Request(page: "monitor:watches", watchID: watchID) }
}
