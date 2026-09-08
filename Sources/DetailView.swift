import SwiftUI
import AppKit
import Translation

struct DetailView: View {
    @EnvironmentObject private var preferences: AppPreferences
    let app: AppEntry
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var suggestionStore = SuggestionStore.shared
    @ObservedObject var detailsStore = AppDetailsStore.shared
    @ObservedObject var categoryStore = CustomCategoryStore.shared
    var onCreateCategory: () -> Void = {}
    @State private var tab = "overview"
    @State private var local = LocalAppDetails()

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
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 250)
                Spacer(minLength: 12)
                if loading {
                    ProgressView().controlSize(.small)
                        .help(preferences.text("info.loading"))
                } else {
                    Button {
                        Task { await detailsStore.load(app: app, language: language, force: true) }
                    } label: {
                        Label(preferences.text("info.refresh"), systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless).help(preferences.text("info.refresh"))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            if tab == "notes" {
                NoteEditorView(app: app, store: store, suggestionStore: suggestionStore)
            } else {
                overview
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                Menu {
                    CategoryMembershipItems(app: app, store: categoryStore, onCreate: onCreateCategory)
                } label: {
                    Label(preferences.text("category.addTo"), systemImage: "folder.badge.plus").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(preferences.text("category.addTo")).accessibilityLabel(preferences.text("category.addTo"))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    openButton
                    if let details { Link(preferences.text("info.appStore"), destination: details.storeURL) }
                    Button(preferences.text("detail.reveal"), action: app.reveal)
                }
                HStack(spacing: 8) {
                    openButton
                    Menu {
                        if let details { Link(preferences.text("info.appStore"), destination: details.storeURL) }
                        Button(preferences.text("detail.reveal"), action: app.reveal)
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

    private var openButton: some View {
        Button(action: app.open) {
            Label(preferences.text("detail.open"), systemImage: "arrow.up.forward")
        }
        .buttonStyle(.borderedProminent)
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
            if let details {
                HStack(alignment: .firstTextBaseline) {
                    Label("App Store · " + regionName(details.country), systemImage: "checkmark.seal")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(details.fetchedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.tertiary)
                        .help(preferences.text("info.fetchedAt"))
                }
            } else {
                Label(preferences.text(loading ? "info.loading" : "info.localSource"),
                      systemImage: loading ? "arrow.triangle.2.circlepath" : "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                Text(title).font(.headline)
                Spacer(minLength: 8)
                actions().controlSize(.small).buttonStyle(.borderless)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1).allowsHitTesting(false)
        }
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
                if original.isEmpty {
                    Text(preferences.text(loading ? "info.loadingDescription" : "info.noDescription"))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                } else {
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
        add("info.installedVersion", app.version)
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
        (values.map { preferences.text($0.key) + ": " + $0.value }
         + requirements.map { $0.platform + ": " + $0.text }
         + [preferences.text("detail.location") + ": " + app.path]).joined(separator: "\n")
    }

    var body: some View {
        InfoCard(title: preferences.text("detail.info"), symbol: "info.circle") {
            CopyButton(text: copyText)
        } content: {
            VStack(spacing: 0) {
                ForEach(values) { item in
                    infoRow(preferences.text(item.key), value: item.value)
                    Divider().opacity(0.65)
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
                    Divider().opacity(0.65)
                }
                infoRow(preferences.text("detail.location"), value: app.path)
                if let copyright = local.copyright, !copyright.isEmpty {
                    Divider().opacity(0.65)
                    infoRow(preferences.text("info.copyright"), value: copyright)
                }
            }
        }
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
                if purchases.isEmpty {
                    Label(preferences.text(message), systemImage: details?.page?.hasInAppPurchases == false ? "checkmark.circle" : "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
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
                }
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
