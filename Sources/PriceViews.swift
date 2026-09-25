import AppKit
import SwiftUI

struct PriceKindBadge: View {
    @EnvironmentObject private var preferences: AppPreferences
    let kind: PriceKind
    var body: some View {
        Label(preferences.text(kind.titleKey), systemImage: kind.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(kind == .application ? Color.blue : Color.purple)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background((kind == .application ? Color.blue : Color.purple).opacity(0.10), in: Radius.shape(6))
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
                Text(event.previous.formatted(locale: preferences.locale) + " → " +
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

struct PriceReminderDetail: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var monitor: PriceMonitorStore
    let eventID: UUID?
    private var event: FreePriceEvent? { monitor.state.events.first { $0.id == eventID } }

    var body: some View {
        Group {
            if let event {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 14) {
                            AppIcon(app: event.app.entry, size: 58)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(event.app.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                                PriceKindBadge(kind: event.kind)
                            }
                        }
                        if event.kind == .inAppPurchase {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(preferences.text("monitor.product")).font(.caption).foregroundStyle(.secondary)
                                Text(event.productName).font(.title3.weight(.medium)).textSelection(.enabled)
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(preferences.text("monitor.dropped")).font(.headline)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(event.previous.formatted(locale: preferences.locale))
                                    .strikethrough().foregroundStyle(.secondary).font(.title3)
                                Text(PriceQuote(amount: 0, currency: event.previous.currency, observedAt: event.confirmedAt)
                                    .formatted(locale: preferences.locale)).font(.system(size: 30, weight: .semibold))
                            }
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Label(preferences.text(event.statusKey(now: context.date)), systemImage: "clock")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if monitor.watch(for: event.app.id)?.isEnabled != true || !monitor.state.automaticChecks {
                                Label(preferences.text("monitor.notChecking"), systemImage: "pause.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: Radius.shape(Radius.surface))
                        VStack(spacing: 12) {
                            LabeledContent(preferences.text("monitor.region"), value: regionName(event.app.country))
                            LabeledContent(preferences.text("monitor.detected")) { Text(event.discoveredAt, style: .date) }
                            LabeledContent(preferences.text("monitor.confirmed")) { Text(event.confirmedAt, format: .dateTime.month().day().hour().minute()) }
                            LabeledContent(preferences.text("monitor.observed")) { Text(event.current.observedAt, format: .dateTime.month().day().hour().minute()) }
                            LabeledContent(preferences.text("monitor.current"), value: event.current.formatted(locale: preferences.locale))
                        }.font(.callout)
                        Text(preferences.text(event.kind == .inAppPurchase ? "monitor.iapNotice" : "monitor.priceNotice"))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Link(destination: event.app.storeURL) {
                            Label(preferences.text("info.viewStore"), systemImage: "arrow.up.right")
                        }.buttonStyle(.borderedProminent)
                        HStack {
                            Button(preferences.text(event.isUnread ? "monitor.read" : "monitor.unread")) {
                                Task { await monitor.markRead([event.id], read: event.isUnread) }
                            }
                            Button(preferences.text(event.archivedAt == nil ? "monitor.archive" : "monitor.unarchive")) {
                                Task { await monitor.archive(event.id, archived: event.archivedAt == nil) }
                            }
                        }.buttonStyle(.bordered).disabled(!monitor.writable)
                    }
                    .padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
                }
            } else {
                EmptyState(symbol: "bell", title: preferences.text("monitor.select"), message: preferences.text("monitor.select.help"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func regionName(_ code: String) -> String {
        (preferences.locale.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()) + " · " + eventPlatform
    }
    private var eventPlatform: String { event?.app.platform == "mac-software" ? "Mac" : "iPhone / iPad" }
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
                                Text(preferences.text(watch.purchaseCoverageKey)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 14) {
                            AppIcon(app: watch.app.entry, size: 58)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(watch.app.name).font(.title2.weight(.semibold))
                                Text((preferences.locale.localizedString(forRegionCode: watch.app.country.uppercased()) ?? watch.app.country.uppercased()) + " · " + (watch.app.platform == "mac-software" ? "Mac" : "iPhone / iPad"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            if watch.watchesApplication { PriceKindBadge(kind: .application) }
                            if watch.watchesPurchases { PriceKindBadge(kind: .inAppPurchase) }
                        }
                        if let key = watch.errorKey {
                            Label(preferences.text(key), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(preferences.text("monitor.latestPrices")).font(.headline)
                            ForEach(watch.products.filter { ($0.kind == .application && watch.watchesApplication) || ($0.kind == .inAppPurchase && watch.watchesPurchases && watch.purchaseSnapshot == nil) }) { product in
                                HStack(alignment: .firstTextBaseline) {
                                    Label(product.kind == .application ? preferences.text("monitor.scope.application") : product.name, systemImage: product.kind.symbol)
                                    Spacer(minLength: 12)
                                    Text(product.unavailable ? preferences.text("monitor.unknown") : (product.latest?.formatted(locale: preferences.locale) ?? preferences.text("monitor.unknown")))
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }.font(.callout)
                            }
                            if watch.watchesPurchases, let snapshot = watch.purchaseSnapshot {
                                // Index identifies rows only within this snapshot, never across price checks.
                                ForEach(Array(snapshot.purchases.enumerated()), id: \.offset) { _, purchase in
                                    HStack(alignment: .firstTextBaseline) {
                                        Label(purchase.name.trimmingCharacters(in: .whitespacesAndNewlines), systemImage: PriceKind.inAppPurchase.symbol)
                                        Spacer(minLength: 12)
                                        Text(purchase.price.isEmpty ? preferences.text("monitor.unknown") : purchase.price)
                                            .foregroundStyle(.secondary).monospacedDigit()
                                    }.font(.callout)
                                }
                                Text(preferences.text("monitor.purchaseSnapshot", snapshot.purchases.count))
                                    .font(.caption).foregroundStyle(.secondary)
                                LabeledContent(preferences.text("monitor.purchaseObserved")) {
                                    Text(snapshot.observedAt, format: .dateTime.month().day().hour().minute())
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            if watch.products.isEmpty && watch.purchaseSnapshot == nil { Text(preferences.text("monitor.unknown")).foregroundStyle(.secondary) }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: Radius.shape(Radius.surface))
                        if watch.watchesPurchases {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(preferences.text(watch.purchaseCoverageKey)).font(.headline)
                                Text(preferences.text("monitor.purchaseCount", watch.purchaseCount)).font(.callout)
                                Text(preferences.text("monitor.iapNotice")).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if let date = watch.lastSuccess {
                            LabeledContent(preferences.text("monitor.lastSuccess")) {
                                Text(date, format: .dateTime.month().day().hour().minute())
                            }.font(.callout)
                        }
                        Text(preferences.text("monitor.runtime")).font(.callout).foregroundStyle(.secondary)
                        Toggle(preferences.text("monitor.watchEnabled"), isOn: Binding(get: { watch.isEnabled }, set: { value in
                            Task { await monitor.setEnabled(value, watchID: watch.id) }
                        })).toggleStyle(.switch).disabled(!monitor.writable)
                        ViewThatFits {
                            HStack { actions(watch) }
                            VStack(alignment: .leading, spacing: 10) { actions(watch) }
                        }.buttonStyle(.bordered)
                        Button(preferences.text("monitor.unfollow"), role: .destructive) {
                            Task { await monitor.remove(watchID: watch.id) }
                        }.buttonStyle(.borderless).disabled(!monitor.writable)
                    }.padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
                }
            } else {
                EmptyState(symbol: "heart", title: preferences.text("monitor.watches.select"), message: preferences.text("monitor.watches.select.help"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { PriceWatchEditor(monitor: monitor, existing: $0) }
    }
    @ViewBuilder private func actions(_ watch: PriceWatch) -> some View {
        Link(preferences.text("info.viewStore"), destination: watch.app.storeURL)
        Button(preferences.text("monitor.edit")) { editing = watch }.disabled(!monitor.writable)
        Button(preferences.text("monitor.check")) { Task { await monitor.refresh(watchID: watch.id, force: true) } }
            .disabled(monitor.isChecking || !watch.isEnabled || !monitor.writable)
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
        VStack(alignment: .leading, spacing: 18) {
            Text(preferences.text(existing == nil ? "monitor.add" : "monitor.edit")).font(.title2.weight(.semibold))
            Text(preferences.text("monitor.add.help")).font(.callout).foregroundStyle(.secondary)
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
                    Text(preferences.text(result.purchaseCoverageKey) + " · " + preferences.text("monitor.purchaseCount", result.purchaseCount))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: Radius.shape(Radius.group))
            }
            HStack(spacing: 24) {
                Toggle(isOn: $application) { Label(preferences.text("monitor.kind.application"), systemImage: PriceKind.application.symbol) }
                Toggle(isOn: $purchases) { Label(preferences.text("monitor.kind.inAppPurchase"), systemImage: PriceKind.inAppPurchase.symbol) }
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
        .padding(24).frame(width: 530)
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
        busy = true
        lookupTask = Task { @MainActor in
            do {
                let fetched = try await monitor.inspect(id: parsed.trackID, country: region, bundle: existing?.app.bundleID ?? entry?.bundleID)
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
