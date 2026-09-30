import AppKit
import SwiftUI

struct PriceKindBadge: View {
    @EnvironmentObject private var preferences: AppPreferences
    let kind: PriceKind
    var isScope = false
    var body: some View {
        Label(preferences.text(isScope ? "monitor.watching.\(kind.rawValue)" : kind.titleKey), systemImage: kind.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(kind == .application ? Color.blue : Color.purple)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background((kind == .application ? Color.blue : Color.purple).opacity(0.10), in: Radius.shape(6))
    }
}

struct PriceRefreshFeedback: View {
    @EnvironmentObject private var preferences: AppPreferences
    let report: PriceRefreshReport
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let cooldownEnded = report.retryAfter.map { $0 <= context.date } ?? false
            VStack(alignment: .leading, spacing: 4) {
                Text(preferences.text(report.disposition == .waiting && cooldownEnded ? "monitor.refresh.ready" : report.messageKey))
                if report.waiting > 0 && !cooldownEnded { Text(preferences.text("monitor.refresh.waitCount", report.waiting)) }
                if let date = report.retryAfter, date > context.date {
                    Text(preferences.text("monitor.refresh.waitSeconds", Int(ceil(date.timeIntervalSince(context.date)))))
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PriceSourceSummary: View {
    @EnvironmentObject private var preferences: AppPreferences
    let titleKey: String
    let observedAt: Date?
    let status: PriceSourceStatus?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(preferences.text(titleKey))
                    Spacer(minLength: 8)
                    if let observedAt {
                        Text(observedAt, format: .dateTime.month().day().hour().minute())
                    } else { Text(preferences.text("monitor.unknown")) }
                }
                if let observedAt, context.date.timeIntervalSince(observedAt) > PriceRules.freshness || status?.failure != nil {
                    Text(preferences.text("monitor.source.stale"))
                }
                if let status, let failure = status.failure {
                    Text(preferences.text(failure.issue.messageKey)).foregroundStyle(.orange)
                    Text(preferences.text("monitor.source.attempt") + " " + status.attemptedAt.formatted(date: .abbreviated, time: .shortened))
                    if let retry = failure.retryAfter, retry > context.date {
                        Text(preferences.text("monitor.source.retry") + " " + retry.formatted(date: .omitted, time: .standard))
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PurchasePriceRows: View {
    @EnvironmentObject private var preferences: AppPreferences
    let watch: PriceWatch
    let snapshot: PurchaseSnapshot
    private var assessments: [PurchaseAssessment] {
        PublicPurchasePrices.assess(snapshot.purchases,
            currency: snapshot.currency ?? watch.products.first(where: { $0.kind == .application })?.latest?.currency)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(assessments.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(item.name, systemImage: PriceKind.inAppPurchase.symbol)
                            Spacer(minLength: 12)
                            Text(item.purchase.price.isEmpty ? preferences.text("monitor.unknown") : item.purchase.price)
                                .fontWeight(.medium).monospacedDigit()
                        }.font(.callout)
                        let status = reason(item, now: context.date)
                        if status != "monitor.comparison.comparable" {
                            Text(preferences.text(status))
                                .font(.caption)
                                .foregroundStyle(status == "monitor.status.free" ? Color.green : .secondary)
                                .padding(.leading, 24)
                                .help(explanation(item))
                        }
                    }
                }
            }
        }
    }
    private func explanation(_ item: PurchaseAssessment) -> String {
        preferences.text(item.comparison.messageKey + ".help")
    }

    private func reason(_ item: PurchaseAssessment, now: Date) -> String {
        guard item.comparison == .comparable else { return item.comparison.messageKey }
        if watch.purchaseStatus?.failure != nil || now.timeIntervalSince(snapshot.observedAt) > PriceRules.freshness {
            return "monitor.comparison.awaiting"
        }
        if item.amount == 0 { return "monitor.status.free" }
        return item.comparison.messageKey
    }
}

struct MonitorFeedback: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var monitor: PriceMonitorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let key = monitor.errorKey {
                Label(preferences.text(key), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
            if let key = monitor.undoMessageKey {
                HStack {
                    Text(preferences.text(key)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(preferences.text("menu.undo")) { Task { await monitor.undo() } }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MonitorCheckFooter: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var monitor: PriceMonitorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonitorFeedback(monitor: monitor)
            if let report = monitor.refreshReport { PriceRefreshFeedback(report: report) }
            HStack(spacing: 8) {
                if monitor.isChecking {
                    ProgressView().controlSize(.small)
                    Text(preferences.text("monitor.checking", monitor.progress, monitor.total))
                } else {
                    Image(systemName: monitor.state.automaticChecks ? "clock" : "pause.circle")
                    Text(preferences.text(monitor.state.automaticChecks ? "monitor.hourly" : "monitor.automatic.off"))
                    Spacer(minLength: 0)
                    Button { Task { await monitor.refresh(force: true) } } label: {
                        Label(preferences.text("monitor.check"), systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless).help(preferences.text("monitor.check.help"))
                    .disabled(!monitor.writable || !monitor.state.watches.contains(where: \.isEnabled))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

struct PriceReminderList: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var monitor: PriceMonitorStore
    @Binding var selection: UUID?
    @State private var scope = "all"
    @State private var query = ""

    private var events: [FreePriceEvent] {
        monitor.sortedEvents.filter { event in
            let included = scope == "archived" ? event.archivedAt != nil :
                event.archivedAt == nil && (scope != "unread" || event.isUnread || event.id == selection)
            let text = event.app.name + " " + event.productName + " " + preferences.text(event.kind.titleKey)
            return included && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(preferences.text("monitor.reminders")).font(.title3.weight(.semibold))
                    Spacer(minLength: 4)
                    Menu {
                        Button(preferences.text("monitor.readAll")) {
                            let ids = Set(monitor.state.events.filter(\.isUnread).map(\.id))
                            Task { await monitor.markRead(ids, read: true, undoable: true) }
                        }.disabled(monitor.unreadCount == 0 || !monitor.writable)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(preferences.text("info.more"))
                }
                Picker(preferences.text("monitor.filter"), selection: $scope) {
                    ForEach(["all", "unread", "archived"], id: \.self) { key in
                        Text(preferences.text("monitor.filter.\(key)")).tag(key)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                SearchField(text: $query, prompt: preferences.text("monitor.search"))
            }.padding(16)
            Divider()
            List(selection: $selection) {
                ForEach(events) { event in
                    PriceReminderRow(event: event).tag(event.id)
                        .contextMenu {
                            Button(preferences.text(event.isUnread ? "monitor.read" : "monitor.unread")) {
                                Task { await monitor.markRead([event.id], read: event.isUnread) }
                            }
                            Button(preferences.text(event.archivedAt == nil ? "monitor.archive" : "monitor.unarchive")) {
                                Task { await monitor.archive(event.id, archived: event.archivedAt == nil) }
                            }
                        }
                }
            }
            .listStyle(.inset).accessibilityIdentifier("monitor.reminderList")
            .overlay {
                if events.isEmpty {
                    EmptyState(symbol: "bell", title: preferences.text(query.isEmpty ? "monitor.empty" : "search.noResults"),
                               message: preferences.text(query.isEmpty ? "monitor.empty.help" : "search.tryAgain"), compact: true)
                        .padding(16).allowsHitTesting(false)
                }
            }
            Divider()
            MonitorCheckFooter(monitor: monitor)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: scope) { _, _ in selection = nil }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            Task { await monitor.markRead([id], read: true) }
        }
    }
}

private struct PriceReminderRow: View {
    @EnvironmentObject private var preferences: AppPreferences
    let event: FreePriceEvent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(app: event.app.entry, size: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.app.name).font(.body.weight(event.isUnread ? .semibold : .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    if event.isUnread { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                }
                PriceKindBadge(kind: event.kind)
                if event.kind == .inAppPurchase {
                    Text(event.productName).font(.callout).lineLimit(2)
                }
                Text((event.previous.amount > 0 ? event.previous.formatted(locale: preferences.locale) + " → " : "") +
                     PriceQuote(amount: 0, currency: event.previous.currency, observedAt: event.confirmedAt).formatted(locale: preferences.locale))
                    .font(.callout).monospacedDigit()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(preferences.text(event.statusKey(now: context.date)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(event.app.country.uppercased() + " · " + event.discoveredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(preferences.locale)))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityValue(preferences.text(event.isUnread ? "monitor.filter.unread" : "monitor.isRead"))
    }
}

private struct MonitorDetailHeader: View {
    @EnvironmentObject private var preferences: AppPreferences
    let app: WatchedApp

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(app: app.entry, size: 56)
                .clipShape(Radius.shape(12))
            VStack(alignment: .leading, spacing: 7) {
                Text(app.name).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text((preferences.locale.localizedString(forRegionCode: app.country.uppercased()) ?? app.country.uppercased())
                    + " · " + (app.platform == "mac-software" ? "Mac" : "iPhone / iPad"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct PriceReminderDetail: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var monitor: PriceMonitorStore
    let eventID: UUID?
    private var event: FreePriceEvent? { monitor.state.events.first { $0.id == eventID } }

    var body: some View {
        Group {
            if let event {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        MonitorDetailHeader(app: event.app)
                        ViewThatFits {
                            HStack(spacing: 10) { actions(event) }
                            VStack(alignment: .leading, spacing: 10) { actions(event) }
                        }.controlSize(.large)

                        DetailCard {
                            HStack {
                                PriceKindBadge(kind: event.kind)
                                Spacer()
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    Label(preferences.text(event.statusKey(now: context.date)),
                                          systemImage: event.status == .ended ? "clock" : "checkmark.circle")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(event.statusKey(now: context.date) == "monitor.status.free" ? Color.green : .secondary)
                                }
                            }
                            Text(event.kind == .inAppPurchase ? event.productName : event.app.name)
                                .font(.title3.weight(.semibold)).textSelection(.enabled)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(event.current.formatted(locale: preferences.locale))
                                    .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                                if event.previous.amount > 0 && event.current.amount == 0 {
                                    Text(event.previous.formatted(locale: preferences.locale))
                                        .font(.title3).strikethrough().foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            HStack {
                                Label(preferences.text("monitor.observed"), systemImage: "clock")
                                Spacer()
                                Text(event.current.observedAt, format: .dateTime.month().day().hour().minute())
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        if monitor.watch(for: event.app.id)?.isEnabled != true || !monitor.state.automaticChecks {
                            Label(preferences.text("monitor.notChecking"), systemImage: "pause.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        DetailCard {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 14) {
                                    LabeledContent(preferences.text("monitor.detected")) {
                                        Text(event.discoveredAt, format: .dateTime.year().month().day().hour().minute())
                                    }
                                    Text(preferences.text(event.kind == .inAppPurchase ? "monitor.iapNotice" : "monitor.priceNotice"))
                                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }.font(.callout).padding(.top, 12)
                            } label: {
                                Label(preferences.text("monitor.offerDetails"), systemImage: "info.circle").font(.headline)
                            }
                        }
                    }
                    .padding(PageStyle.inset).frame(maxWidth: PageStyle.width, alignment: .leading).frame(maxWidth: .infinity)
                }.id(event.id)
            } else {
                EmptyState(symbol: "bell", title: preferences.text("monitor.select"), message: preferences.text("monitor.select.help"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func actions(_ event: FreePriceEvent) -> some View {
        Link(destination: event.app.storeURL) {
            Label(preferences.text("info.viewStore"), systemImage: "arrow.up.right")
        }.buttonStyle(.borderedProminent)
        Button {
            Task { await monitor.markRead([event.id], read: event.isUnread) }
        } label: {
            Label(preferences.text(event.isUnread ? "monitor.read" : "monitor.unread"),
                  systemImage: event.isUnread ? "envelope.open" : "envelope.badge")
        }.buttonStyle(.bordered).disabled(!monitor.writable)
        Button {
            Task { await monitor.archive(event.id, archived: event.archivedAt == nil) }
        } label: {
            Label(preferences.text(event.archivedAt == nil ? "monitor.archive" : "monitor.unarchive"),
                  systemImage: "archivebox")
        }.buttonStyle(.bordered).disabled(!monitor.writable)
    }
}

struct PriceWatchList: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var monitor: PriceMonitorStore
    @Binding var selection: String?
    @State private var query = ""
    @State private var adding = false
    private var watches: [PriceWatch] {
        monitor.state.watches.filter {
            query.isEmpty || $0.app.name.localizedCaseInsensitiveContains(query) ||
            $0.products.contains { $0.name.localizedCaseInsensitiveContains(query) } ||
            $0.purchaseSnapshot?.purchases.contains { $0.name.localizedCaseInsensitiveContains(query) } == true
        }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text(preferences.text("monitor.watches")).font(.title3.weight(.semibold))
                    Spacer(minLength: 4)
                    Button { adding = true } label: {
                        Label(preferences.text("monitor.add"), systemImage: "plus").labelStyle(.iconOnly)
                    }.buttonStyle(.borderless).disabled(!monitor.writable)
                    .accessibilityIdentifier("monitor.add")
                }
                SearchField(text: $query, prompt: preferences.text("monitor.search"))
            }.padding(16)
            Divider()
            List(selection: $selection) {
                ForEach(watches) { watch in
                    HStack(alignment: .top, spacing: 10) {
                        AppIcon(app: watch.app.entry, size: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(watch.app.name).font(.body.weight(.medium)).lineLimit(2)
                            Text(watch.app.country.uppercased() + " · " + (watch.app.platform == "mac-software" ? "Mac" : "iPhone / iPad"))
                                .font(.caption).foregroundStyle(.secondary)
                            if !watch.isEnabled {
                                Label(preferences.text("monitor.paused"), systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                            } else if let error = watch.errorKey {
                                Label(preferences.text(error), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            } else {
                                Text(preferences.text(watch.watchesPurchases ? watch.purchaseCoverageKey : "monitor.watching.application"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }.padding(.vertical, 8).tag(watch.id)
                }
            }.listStyle(.inset).accessibilityIdentifier("monitor.watchList")
            .overlay {
                if watches.isEmpty {
                    VStack(spacing: 12) {
                        EmptyState(symbol: "heart", title: preferences.text("monitor.watches.empty"),
                                   message: preferences.text("monitor.watches.empty.help"), compact: true)
                        Button(preferences.text("monitor.add")) { adding = true }.disabled(!monitor.writable)
                    }.padding(16)
                }
            }
            Divider()
            MonitorCheckFooter(monitor: monitor)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $adding) { PriceWatchEditor(monitor: monitor) }
    }
}

struct PriceWatchDetail: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var monitor: PriceMonitorStore
    let watchID: String?
    @State private var editing: PriceWatch?
    private var watch: PriceWatch? { watchID.flatMap(monitor.watch(for:)) }

    var body: some View {
        Group {
            if let watch {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        MonitorDetailHeader(app: watch.app)
                        ViewThatFits {
                            HStack(spacing: 10) { actions(watch) }
                            VStack(alignment: .leading, spacing: 10) { actions(watch) }
                        }.controlSize(.large)
                        if let report = monitor.watchReports[watch.id] {
                            PriceRefreshFeedback(report: report)
                        }
                        prices(watch)
                        monitoring(watch)
                        DetailCard {
                            DisclosureGroup {
                                sourceDetails(watch).padding(.top, 12)
                            } label: {
                                Label(preferences.text("monitor.checkDetails"), systemImage: "info.circle").font(.headline)
                            }
                        }
                    }
                    .padding(PageStyle.inset).frame(maxWidth: PageStyle.width, alignment: .leading).frame(maxWidth: .infinity)
                }.id(watch.id)
            } else {
                EmptyState(symbol: "heart", title: preferences.text("monitor.watches.select"), message: preferences.text("monitor.watches.select.help"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { PriceWatchEditor(monitor: monitor, existing: $0) }
    }

    private func prices(_ watch: PriceWatch) -> some View {
        DetailCard {
            Text(preferences.text("monitor.latestPrices")).font(.headline)
            ForEach(watch.products.filter {
                ($0.kind == .application && watch.watchesApplication) ||
                ($0.kind == .inAppPurchase && watch.watchesPurchases && watch.purchaseSnapshot == nil)
            }) { product in
                HStack(alignment: .firstTextBaseline) {
                    Label(product.kind == .application ? preferences.text("monitor.scope.application") : product.name,
                          systemImage: product.kind.symbol)
                    Spacer(minLength: 12)
                    Text(product.latest?.formatted(locale: preferences.locale) ?? preferences.text("monitor.unknown"))
                        .fontWeight(.medium).monospacedDigit()
                }.font(.callout)
            }
            if watch.watchesPurchases, let snapshot = watch.purchaseSnapshot {
                if watch.watchesApplication { Divider() }
                HStack {
                    Text(preferences.text("monitor.purchaseSection")).font(.caption.weight(.medium))
                    Spacer()
                    Text(preferences.text("monitor.purchaseItems", snapshot.purchases.count)).font(.caption)
                }.foregroundStyle(.secondary)
                PurchasePriceRows(watch: watch, snapshot: snapshot)
            }
            if watch.products.isEmpty && watch.purchaseSnapshot == nil {
                Text(preferences.text("monitor.unknown")).foregroundStyle(.secondary)
            }
        }
    }

    private func monitoring(_ watch: PriceWatch) -> some View {
        DetailCard {
            Toggle(isOn: Binding(get: { watch.isEnabled }, set: { value in
                Task { await monitor.setEnabled(value, watchID: watch.id) }
            })) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preferences.text("monitor.watchEnabled")).font(.headline)
                    Text(preferences.text(!watch.isEnabled ? "monitor.paused" :
                        monitor.state.automaticChecks ? "monitor.schedule" : "monitor.automatic.manualOnly"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).disabled(!monitor.writable)
            HStack(spacing: 8) {
                if watch.watchesApplication { PriceKindBadge(kind: .application, isScope: true) }
                if watch.watchesPurchases { PriceKindBadge(kind: .inAppPurchase, isScope: true) }
            }
            if let error = watch.errorKey {
                Label(preferences.text(error), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if let date = watch.lastSuccess {
                HStack {
                    Label(preferences.text("monitor.lastChecked"), systemImage: "clock")
                    Spacer()
                    Text(date, format: .dateTime.month().day().hour().minute())
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sourceDetails(_ watch: PriceWatch) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if watch.applicationStatus == nil || (watch.watchesPurchases && watch.purchaseStatus == nil) {
                Text(preferences.text("monitor.source.legacy")).font(.caption)
            }
            if watch.watchesApplication {
                PriceSourceSummary(titleKey: "monitor.applicationObserved",
                    observedAt: watch.products.first(where: { $0.kind == .application })?.latest?.observedAt,
                    status: watch.applicationStatus)
            }
            if watch.watchesPurchases {
                PriceSourceSummary(titleKey: "monitor.purchaseObserved",
                    observedAt: watch.purchaseSnapshot?.observedAt, status: watch.purchaseStatus)
                Text(preferences.text(watch.purchaseCoverageKey) + " · " + preferences.text("monitor.purchaseCount", watch.purchaseCount))
                    .font(.caption)
                Text(preferences.text("monitor.iapNotice")).font(.callout)
            }
            if watch.isEnabled && monitor.state.automaticChecks {
                LabeledContent(preferences.text("monitor.source.next")) {
                    Text(watch.nextCheck, format: .dateTime.month().day().hour().minute())
                }.font(.caption)
            }
            Text(preferences.text("monitor.runtime")).font(.callout)
        }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func actions(_ watch: PriceWatch) -> some View {
        Button {
            Task { await monitor.refresh(watchID: watch.id, force: true) }
        } label: {
            Label(preferences.text(monitor.isChecking ? "monitor.refreshing" : "monitor.check"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!watch.isEnabled || !monitor.writable || monitor.isChecking)
        .accessibilityIdentifier("monitor.checkWatch")
        Link(destination: watch.app.storeURL) {
            Label(preferences.text("info.viewStore"), systemImage: "arrow.up.right")
        }.buttonStyle(.bordered)
        Menu {
            Button(preferences.text("monitor.edit")) { editing = watch }
            Divider()
            Button(preferences.text("monitor.unfollow"), role: .destructive) {
                Task { await monitor.remove(watchID: watch.id) }
            }
        } label: {
            Label(preferences.text("monitor.edit"), systemImage: "ellipsis")
        }.menuStyle(.borderlessButton).fixedSize().disabled(!monitor.writable)
    }
}

struct PriceWatchEditor: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: PriceMonitorStore
    var entry: AppEntry? = nil
    var existing: PriceWatch? = nil
    @State private var link = ""
    @State private var country = "cn"
    @State private var application = true
    @State private var purchases = true
    @State private var result: PriceCheckResult?
    @State private var busy = false
    @State private var saving = false
    @State private var message: String?
    @State private var lookupTask: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: PageStyle.spacing) {
            PageHeading(title: preferences.text(existing == nil ? "monitor.add" : "monitor.edit"),
                subtitle: preferences.text("monitor.add.help"), symbol: "heart")
            VStack(alignment: .leading, spacing: 8) {
                TextField(preferences.text("monitor.link"), text: $link).textFieldStyle(.roundedBorder)
                    .disabled(existing != nil || saving).accessibilityIdentifier("monitor.link")
                HStack {
                    Text(preferences.text("monitor.region"))
                    Picker(preferences.text("monitor.region"), selection: $country) {
                        ForEach(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.sorted(), id: \.self) { code in
                            Text((preferences.locale.localizedString(forRegionCode: code) ?? code) + " (\(code))").tag(code.lowercased())
                        }
                    }.labelsHidden().frame(maxWidth: 250).disabled(saving)
                    Spacer(minLength: 0)
                    Button(preferences.text("monitor.lookup"), action: lookup).disabled(busy || saving || link.isEmpty)
                        .accessibilityIdentifier("monitor.lookup")
                }
            }
            if busy { ProgressView(preferences.text("monitor.lookup.loading")).controlSize(.small) }
            if let result {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AppIcon(app: result.app.entry, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.app.name).font(.headline)
                            Text(result.app.country.uppercased() + " · " + (result.app.platform == "mac-software" ? "Mac" : "iPhone / iPad"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(preferences.text("monitor.previewPrice") + " " + (result.quotes.first(where: { $0.kind == .application })?.price.formatted(locale: preferences.locale) ?? preferences.text("monitor.unknown")))
                        .font(.callout)
                    if purchases {
                        Text(preferences.text(result.purchaseCoverageKey) + " · " + preferences.text("monitor.purchaseCount", result.purchaseCount))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).elevatedCard()
            }
            HStack(spacing: 24) {
                Toggle(isOn: $application) { Label(preferences.text("monitor.watching.application"), systemImage: PriceKind.application.symbol) }
                Toggle(isOn: $purchases) { Label(preferences.text("monitor.watching.inAppPurchase"), systemImage: PriceKind.inAppPurchase.symbol) }
            }.disabled(saving)
            Text(preferences.text(purchases ? "monitor.iapNotice" : "monitor.priceNotice"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(preferences.text(existing == nil ? "monitor.baselineNotice" : "monitor.regionNotice"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message { Label(preferences.text(message), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(preferences.text("fetch.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(preferences.text(existing == nil ? "monitor.follow" : "category.save")) { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(result == nil || busy || saving || (!application && !purchases) || !monitor.writable)
                    .accessibilityIdentifier("monitor.save")
            }
        }
        .padding(PageStyle.inset).frame(width: 570)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let existing {
                link = existing.app.storeURL.absoluteString
                country = existing.app.country
                application = existing.watchesApplication
                purchases = existing.watchesPurchases
            } else if let id = entry?.appStoreID {
                country = entry?.storeCountryCode ?? "cn"
                link = "https://apps.apple.com/\(country)/app/id\(id)"
            }
        }
        .onChange(of: link) { _, value in
            invalidate()
            if let code = AppStoreLink.parse(value)?.countryCode { country = code }
        }
        .onChange(of: country) { _, _ in invalidate() }
        .onChange(of: purchases) { _, _ in invalidate() }
        .onDisappear { lookupTask?.cancel() }
    }

    private func invalidate() {
        lookupTask?.cancel()
        generation = UUID()
        result = nil
        message = nil
        busy = false
    }
    private func lookup() {
        guard let parsed = AppStoreLink.parse(link) else { message = "monitor.error.link"; return }
        invalidate()
        let token = generation
        let region = country
        let includePurchases = purchases
        busy = true
        lookupTask = Task { @MainActor in
            do {
                let fetched = try await monitor.inspect(id: parsed.trackID, country: region, bundle: existing?.app.bundleID ?? entry?.bundleID, purchases: includePurchases)
                guard !Task.isCancelled, generation == token else { return }
                result = fetched
                busy = false
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                message = (error as? PriceClientError)?.messageKey ?? "monitor.error.network"
                busy = false
            }
        }
    }
    private func save() {
        guard let result else { return }
        saving = true
        Task { @MainActor in
            let saved = await monitor.follow(result, application: application, purchases: purchases, replacing: existing)
            saving = false
            if saved { dismiss() } else { message = monitor.errorKey }
        }
    }
}
