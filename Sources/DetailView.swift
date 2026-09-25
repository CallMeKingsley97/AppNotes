import SwiftUI
import AppKit
import Translation

struct DetailView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: AppEntry
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var suggestionStore = SuggestionStore.shared
    @ObservedObject var detailsStore = AppDetailsStore.shared
    @ObservedObject var categoryStore = CustomCategoryStore.shared
    @ObservedObject var imports = ManualImportStore.shared
    @ObservedObject var library = AppLibrary.shared
    @ObservedObject var monitor = PriceMonitorStore.shared
    @State private var showingWatch = false
    var onCreateCategory: () -> Void = {}
    @State private var tab = "overview"
    @State private var local = LocalAppDetails()
    @State private var refreshID = 0
    @State private var refreshConfirmed = false
    @State private var confirmationID = 0

    private var language: String { preferences.language.resolvedIdentifier() }
    private var requestKey: String { AppDetailsStore.key(for: app, language: language) }
    private var details: AppDetails? { detailsStore.details(for: app, language: language) }
    private var loading: Bool { detailsStore.loading.contains(requestKey) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                Picker(preferences.text("info.section"), selection: $tab) {
                    Text(preferences.text("info.overview")).tag("overview")
                    Text(preferences.text("detail.note")).tag("notes")
                    Text(preferences.text("info.updates")).tag("updates")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 330)
                Spacer(minLength: 12)
                refreshButton
            }
            .padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            Group {
                if tab == "notes" {
                    NoteEditorView(app: app, store: store, suggestionStore: suggestionStore)
                        .transition(.opacity)
                } else if tab == "updates" {
                    AppUpdatesView(details: details, loading: loading)
                        .transition(.opacity)
                } else {
                    overview.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Motion.content(reduced: reduceMotion), value: tab)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingWatch) {
            PriceWatchEditor(monitor: monitor, entry: watchEntry,
                existing: monitor.state.watches.first { $0.app.storeID == watchEntry.appStoreID })
        }
        .task(id: requestKey) {
            let path = app.path
            let localDetails = await Task.detached(priority: .utility) { LocalAppDetails.read(path: path) }.value
            guard !Task.isCancelled else { return }
            local = localDetails
            await detailsStore.load(app: app, language: language)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AppIcon(app: app, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.system(size: 23, weight: .semibold))
                        .lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(preferences.text(AppCategory.of(app).titleKey))
                            .font(.callout).foregroundStyle(.secondary)
                        if let listing = details?.listing, let count = listing.userRatingCount, count > 0,
                           let rating = listing.averageUserRating, (0...5).contains(rating) {
                            Text("·").foregroundStyle(.tertiary)
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange)
                            Text(rating, format: .number.precision(.fractionLength(1))).font(.callout.weight(.medium))
                        }
                    }
                }
                Spacer(minLength: 0)
                CategoryPickerButton(app: app, store: categoryStore, onCreate: onCreateCategory)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if app.origin != .manual { openButton }
                    headerActions
                }
                HStack(spacing: 8) {
                    if app.origin != .manual { openButton }
                    Menu {
                        headerActions
                    } label: {
                        Label(preferences.text("info.more"), systemImage: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .buttonStyle(.bordered).controlSize(.regular)
            let categories = categoryStore.categories.filter { categoryStore.contains(app, in: $0) }
            if !categories.isEmpty {
                Label(categories.map(\.name).joined(separator: preferences.language.resolvedIdentifier() == "zh-Hans" ? "、" : ", "),
                      systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).help(categories.map(\.name).joined(separator: "\n"))
            }
        }
        .padding(24)
    }

    private var watchEntry: AppEntry {
        let listing = details?.listing
        return AppEntry(path: app.path, name: app.name, bundleID: listing?.bundleId ?? app.bundleID,
            version: app.version, appStoreID: listing?.trackId ?? app.appStoreID,
            storefrontCountryCode: details?.country ?? app.storefrontCountryCode,
            origin: app.origin, artworkURL: app.artworkURL)
    }

    @ViewBuilder private var headerActions: some View {
        if watchEntry.appStoreID != nil {
            Button { showingWatch = true } label: {
                Label(preferences.text(monitor.state.watches.contains { $0.app.storeID == watchEntry.appStoreID } ? "monitor.edit" : "monitor.follow"), systemImage: "heart")
            }.disabled(!monitor.writable)
        }
        if let destination = storeDestination {
            Link(preferences.text(app.origin == .manual ? "info.viewStore" : "info.appStore"), destination: destination)
        }
        if app.origin == .manual {
            Button(preferences.text("import.remove"), action: removeImport)
        } else {
            Button(preferences.text("detail.reveal"), action: app.reveal)
        }
    }

    private var storeDestination: URL? {
        if let details { return details.storeURL }
        guard app.origin == .manual, let id = app.appStoreID else { return nil }
        return URL(string: "https://apps.apple.com/\(app.storeCountryCode)/app/id\(id)")
    }

    private func removeImport() {
        guard let id = app.appStoreID else { return }
        imports.remove(id)
        library.reloadImports()
    }

    private var openButton: some View {
        Button(action: app.open) {
            Label(preferences.text("detail.open"), systemImage: "arrow.up.forward")
        }
        .buttonStyle(.borderedProminent)
    }

    private var refreshButton: some View {
        Button {
            refreshID += 1
        } label: {
            Label(preferences.text("info.refresh"), systemImage: refreshConfirmed ? "checkmark" : "arrow.clockwise")
                .labelStyle(.iconOnly)
                .opacity(loading ? 0 : 1)
        }
        .buttonStyle(IconButtonStyle(tint: refreshConfirmed ? .green : .primary))
        .allowsHitTesting(!loading)
        .accessibilityRespondsToUserInteraction(!loading)
        .overlay {
            if loading {
                ProgressView().controlSize(.small)
            }
        }
        .animation(Motion.content(reduced: reduceMotion), value: loading)
        .animation(Motion.content(reduced: reduceMotion), value: refreshConfirmed)
        .help(preferences.text(loading ? "info.loading" : "info.refresh"))
        .accessibilityLabel(preferences.text(loading ? "info.loading" : "info.refresh"))
        .task(id: refreshID) {
            guard refreshID > 0 else { return }
            await detailsStore.load(app: app, language: language, force: true)
            guard !Task.isCancelled, detailsStore.errors[requestKey] == nil else { return }
            refreshConfirmed = true
            confirmationID += 1
        }
        .task(id: confirmationID) {
            guard confirmationID > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            refreshConfirmed = false
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceStatus
                AppIntroductionCard(details: details, suggestion: suggestionStore.raw(for: app.path), loading: loading)
                AppInformationCard(app: app, details: details, local: local)
                InAppPurchasesCard(details: details, loading: loading)
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private var sourceStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let details {
                    HStack(alignment: .firstTextBaseline) {
                        Label("App Store · " + regionName(details.country), systemImage: "checkmark.seal")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(details.fetchedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.tertiary)
                            .help(preferences.text("info.fetchedAt"))
                    }
                    .transition(.opacity)
                } else if app.origin == .manual && !loading {
                    Label(preferences.text("category.manual"), systemImage: "square.and.arrow.down")
                        .font(.caption).foregroundStyle(.secondary)
                        .transition(.opacity)
                } else {
                    Label(preferences.text(loading ? "info.loading" : "info.localSource"),
                          systemImage: loading ? "arrow.triangle.2.circlepath" : "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .motionCrossfade(id: details?.fetchedAt ?? (loading ? .distantPast : .distantFuture))
            if let error = detailsStore.errors[requestKey] {
                Text(preferences.text(error))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func regionName(_ code: String) -> String {
        preferences.locale.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }
}

struct InfoCard<Actions: View, Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.08), in: Radius.shape(Radius.control))
                Text(title).font(.headline)
                Spacer(minLength: 8)
                actions().controlSize(.small).buttonStyle(.borderless)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard()
    }
}

struct CopyButton: View {
    @EnvironmentObject private var preferences: AppPreferences
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Label(preferences.text(copied ? "info.copied" : "info.copy"),
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(IconButtonStyle(tint: copied ? .green : .primary))
        .disabled(text.isEmpty)
        .help(preferences.text(copied ? "info.copied" : "info.copy"))
        .task(id: copied) {
            if copied {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
        }
    }
}

struct AppIntroductionCard: View {
    @EnvironmentObject private var preferences: AppPreferences
    let details: AppDetails?
    let suggestion: AppSuggestion?
    let loading: Bool
    @State private var expanded = false
    @State private var translation: String?
    @State private var translating = false
    @State private var translationError = false
    @State private var configuration: TranslationSession.Configuration?

    private var original: String {
        let description = details?.listing.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return description.isEmpty ? (suggestion?.text ?? "") : description
    }
    private var displayed: String { translation ?? original }

    var body: some View {
        InfoCard(title: preferences.text("info.introduction"), symbol: "text.alignleft") {
            HStack(spacing: 14) {
                if translating {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        if translation != nil {
                            translation = nil
                        } else {
                            translating = true
                            if configuration == nil {
                                configuration = TranslationSession.Configuration(
                                    target: Locale.Language(identifier: preferences.language.resolvedIdentifier()))
                            } else {
                                configuration?.invalidate()
                            }
                        }
                    } label: {
                        Label(preferences.text(translation == nil ? "info.translate" : "info.original"),
                              systemImage: translation == nil ? "character.bubble" : "text.bubble")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(original.isEmpty)
                    .help(preferences.text(translation == nil ? "info.translate" : "info.original"))
                }
                CopyButton(text: displayed)
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if let listing = details?.listing, let seller = listing.sellerName ?? listing.artistName {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preferences.text("info.developer")).font(.caption).foregroundStyle(.secondary)
                            Text(seller).font(.callout.weight(.medium)).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        if let url = URL.web(listing.sellerUrl ?? listing.artistViewUrl) {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                .help(preferences.text("info.developerWebsite"))
                                .accessibilityLabel(preferences.text("info.developerWebsite"))
                        }
                    }
                    Divider()
                } else if let suggestion, !original.isEmpty {
                    Text(preferences.text(suggestion.source == "brew" ? "suggestion.brew" : "suggestion.appstore"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Group {
                    if original.isEmpty {
                        Text(preferences.text(loading ? "info.loadingDescription" : "info.noDescription"))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                            .transition(.opacity)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            if translation != nil {
                                Label(preferences.text("info.translated"), systemImage: "character.bubble")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(displayed).font(.system(size: 13)).lineSpacing(5)
                                .foregroundStyle(.primary).textSelection(.enabled)
                                .lineLimit(expanded ? nil : 8).fixedSize(horizontal: false, vertical: true)
                            if !displayed.isEmpty {
                                Button {
                                    expanded.toggle()
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(preferences.text(expanded ? "info.showLess" : "info.showMore"))
                                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                                    }
                                    .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .motionCrossfade(id: original.isEmpty ? (loading ? "loading" : "empty") : "ready")
            }
        }
        .translationTask(configuration) { session in
            let source = original
            let language = preferences.language.resolvedIdentifier()
            do {
                let response = try await session.translate(source)
                guard !Task.isCancelled, source == original,
                      language == preferences.language.resolvedIdentifier() else { return }
                translation = response.targetText
            } catch {
                guard !Task.isCancelled, source == original,
                      language == preferences.language.resolvedIdentifier() else { return }
                translationError = true
            }
            translating = false
        }
        .onChange(of: original) { _, _ in resetTranslation() }
        .onChange(of: preferences.language) { _, _ in resetTranslation() }
        .alert(preferences.text("info.translationFailed"), isPresented: $translationError) {
            Button(preferences.text("info.ok"), role: .cancel) {}
        } message: {
            Text(preferences.text("info.translationHelp"))
        }
    }

    private func resetTranslation() {
        translation = nil
        configuration = nil
        translating = false
        translationError = false
    }
}

private struct InformationValue: Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

struct AppInformationCard: View {
    @EnvironmentObject private var preferences: AppPreferences
    let app: AppEntry
    let details: AppDetails?
    let local: LocalAppDetails

    private var values: [InformationValue] {
        let listing = details?.listing
        var result: [InformationValue] = []
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { result.append(InformationValue(key: key, value: value)) }
        }
        add("info.appID", (listing?.trackId ?? app.appStoreID).map(String.init))
        add("detail.bundle", app.bundleID ?? listing?.bundleId)
        if app.origin == .manual {
            if listing?.version == nil { add("info.storeVersion", app.version) }
        } else {
            add("info.installedVersion", app.version)
        }
        add("info.storeVersion", listing?.version)
        add("info.price", price)
        if let size = listing?.fileSizeBytes.flatMap(Int64.init), size >= 0 {
            add("info.size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        let separator = preferences.language.resolvedIdentifier() == "zh-Hans" ? "、" : ", "
        add("info.category", listing?.genres?.joined(separator: separator))
        add("info.ageRating", listing?.contentAdvisoryRating)
        let languages = listing?.languageCodesISO2A ?? local.languages
        add("info.languages", languages.map {
            preferences.locale.localizedString(forLanguageCode: $0.lowercased()) ?? $0
        }.joined(separator: separator))
        if let dateString = listing?.currentVersionReleaseDate,
           let date = ISO8601DateFormatter().date(from: dateString) {
            add("info.updated", date.formatted(.dateTime.year().month().day().locale(preferences.locale)))
        }
        if let count = listing?.userRatingCount, count > 0,
           let rating = listing?.averageUserRating, (0...5).contains(rating) {
            let score = rating.formatted(.number.precision(.fractionLength(1)).locale(preferences.locale))
            add("info.rating", preferences.text("info.ratingValue", score, count))
        }
        return result
    }

    private var price: String? {
        guard let listing = details?.listing else { return nil }
        if listing.price == 0 { return preferences.text("info.free") }
        if let amount = listing.price, amount >= 0, let currency = listing.currency {
            return amount.formatted(.currency(code: currency).locale(preferences.locale))
        }
        return listing.formattedPrice
    }

    private var requirements: [AppRequirement] {
        if let page = details?.page, !page.requirements.isEmpty { return page.requirements }
        if details?.listing.kind == "mac-software", let minimum = details?.listing.minimumOsVersion {
            return [AppRequirement(platform: "Mac", text: preferences.text("info.macOS", minimum))]
        }
        if let minimum = local.minimumSystem {
            return [AppRequirement(platform: "Mac", text: preferences.text("info.macOS", minimum))]
        }
        return []
    }

    private var copyText: String {
        var lines = values.map { preferences.text($0.key) + ": " + $0.value }
            + requirements.map { $0.platform + ": " + $0.text }
        if app.origin != .manual {
            lines.append(preferences.text("detail.location") + ": " + app.path)
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        InfoCard(title: preferences.text("detail.info"), symbol: "info.circle") {
            CopyButton(text: copyText)
        } content: {
            VStack(spacing: 0) {
                ForEach(values) { item in
                    infoRow(preferences.text(item.key), value: item.value)
                    if item.id != values.last?.id || hasInformationFooter {
                        Divider().opacity(0.65)
                    }
                }
                if !requirements.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(preferences.text("info.compatibility")).font(.callout).foregroundStyle(.secondary)
                        ForEach(Array(requirements.enumerated()), id: \.offset) { _, requirement in
                            VStack(alignment: .leading, spacing: 4) {
                                if !requirement.platform.isEmpty { Text(requirement.platform).font(.callout.weight(.medium)) }
                                Text(requirement.text).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
                    if app.origin != .manual || (local.copyright?.isEmpty == false) {
                        Divider().opacity(0.65)
                    }
                }
                if app.origin != .manual {
                    infoRow(preferences.text("detail.location"), value: app.path)
                }
                if let copyright = local.copyright, !copyright.isEmpty {
                    if app.origin != .manual { Divider().opacity(0.65) }
                    infoRow(preferences.text("info.copyright"), value: copyright)
                }
            }
        }
    }

    private var hasInformationFooter: Bool {
        !requirements.isEmpty || app.origin != .manual || local.copyright?.isEmpty == false
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout).padding(.vertical, 11)
    }
}

struct InAppPurchasesCard: View {
    @EnvironmentObject private var preferences: AppPreferences
    let details: AppDetails?
    let loading: Bool

    private var purchases: [InAppPurchase] { details?.page?.purchases ?? [] }
    private var message: String {
        if loading && details == nil { return "info.loadingPurchases" }
        if details?.page?.hasInAppPurchases == false { return "info.noPurchases" }
        return "info.purchasesUnavailable"
    }

    var body: some View {
        InfoCard(title: preferences.text("info.purchases"), symbol: "bag") {
            if !purchases.isEmpty {
                CopyButton(text: purchases.map { $0.name + "  " + $0.price }.joined(separator: "\n"))
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if purchases.isEmpty {
                        Label(preferences.text(message), systemImage: details?.page?.hasInAppPurchases == false ? "checkmark.circle" : "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                            .transition(.opacity)
                    } else {
                        ForEach(Array(purchases.enumerated()), id: \.offset) { index, purchase in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(purchase.name).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(purchase.price).fontWeight(.medium).monospacedDigit().fixedSize()
                            }
                            .font(.callout).padding(.vertical, 12)
                            if index < purchases.count - 1 { Divider().opacity(0.65) }
                        }
                        .transition(.opacity)
                    }
                }
                .motionCrossfade(id: purchases.isEmpty ? message : "\(purchases.count)")
                if let details {
                    Divider().padding(.vertical, 12)
                    Text(preferences.text("info.purchaseFootnote",
                                          preferences.locale.localizedString(forRegionCode: details.country.uppercased()) ?? details.country.uppercased()))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(preferences.text("info.viewStore"), destination: details.storeURL)
                        .font(.caption).padding(.top, 8)
                }
            }
        }
    }
}

private struct AppUpdatesView: View {
    @EnvironmentObject private var preferences: AppPreferences
    let details: AppDetails?
    let loading: Bool

    private var updates: [AppReleaseNote] { details?.page?.releaseNotes ?? [] }

    var body: some View {
        ScrollView {
            AppUpdatesCard(updates: updates, country: details?.country, loading: loading)
                .padding(24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
        }
    }
}

struct AppUpdatesCard: View {
    @EnvironmentObject private var preferences: AppPreferences
    let updates: [AppReleaseNote]
    let country: String?
    let loading: Bool

    private var copyText: String {
        updates.map { update in
            let date = update.date?.formatted(.dateTime.year().month().day().locale(preferences.locale)) ?? update.releaseDate
            return "\(preferences.text("detail.version")) \(update.version) · \(date)\n\(update.notes)"
        }.joined(separator: "\n\n")
    }
    private var regionName: String? {
        guard let country else { return nil }
        return preferences.locale.localizedString(forRegionCode: country.uppercased()) ?? country.uppercased()
    }

    var body: some View {
        InfoCard(title: preferences.text("info.updates"), symbol: "clock.badge.checkmark") {
            if !updates.isEmpty { CopyButton(text: copyText) }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if updates.isEmpty {
                        Label(preferences.text(loading ? "info.loadingUpdates" : "info.updatesUnavailable"),
                              systemImage: loading ? "arrow.triangle.2.circlepath" : "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                            .transition(.opacity)
                    } else {
                        ForEach(Array(updates.enumerated()), id: \.offset) { index, update in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(preferences.text("detail.version") + " " + update.version)
                                    .font(.callout.weight(.medium))
                                if let date = update.date {
                                    Text(date, format: .dateTime.year().month().day().locale(preferences.locale))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                            }
                            Text(update.notes).font(.callout).lineSpacing(5)
                                .foregroundStyle(.primary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 13)
                        if index < updates.count - 1 { Divider().opacity(0.65) }
                    }
                    .transition(.opacity)
                }
                }
                .motionCrossfade(id: updates.isEmpty ? (loading ? "loading" : "empty") : "\(updates.count)")
                if regionName != nil {
                    Divider().padding(.vertical, 12)
                    Text(preferences.text("info.updatesFootnote", regionName!))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
