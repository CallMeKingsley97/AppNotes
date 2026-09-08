import SwiftUI
import AppKit

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, noted, system, appStore, downloaded
    var id: Self { self }
    var titleKey: String {
        switch self {
        case .all: return "library.all"
        case .noted: return "library.noted"
        default: return "category.\(rawValue)"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .noted: return "note.text"
        default: return AppCategory(rawValue: rawValue)!.symbolName
        }
    }
    func contains(_ app: AppEntry, store: NotesStore) -> Bool {
        switch self {
        case .all: return true
        case .noted: return !store.note(for: app.path).isEmpty
        default: return AppCategory.of(app).rawValue == rawValue
        }
    }
}

struct ManagerView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var suggestionStore = SuggestionStore.shared
    @ObservedObject var library = AppLibrary.shared
    @ObservedObject var detailsStore = AppDetailsStore.shared
    @ObservedObject var categoryStore = CustomCategoryStore.shared
    @State private var query = ""
    @State private var selection: String?
    @State private var filter: String? = LibraryFilter.all.rawValue
    @State private var categoryEditor: CustomAppCategory?
    @State private var showingNewCategory = false
    @State private var newCategoryApp: AppEntry?
    @State private var managingCategory: CustomAppCategory?
    let onSettings: () -> Void
    let onSearch: () -> Void

    private var activeFilter: LibraryFilter? { LibraryFilter(rawValue: filter ?? "") }
    private var activeCustomCategory: CustomAppCategory? {
        guard let filter, filter.hasPrefix("custom:") else { return nil }
        return categoryStore.categories.first { $0.id.uuidString == String(filter.dropFirst(7)) }
    }
    private var filtered: [AppEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.apps.filter { app in
            let belongs = activeFilter?.contains(app, store: store) ?? (activeCustomCategory.map { categoryStore.contains(app, in: $0) } ?? false)
            return belongs && (term.isEmpty || app.matches(term, note: store.note(for: app.path)))
        }
    }
    private var selectedApp: AppEntry? { library.apps.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 195, max: 240)
        } content: {
            appList
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            Group {
                if let app = selectedApp {
                    DetailView(app: app, store: store, suggestionStore: suggestionStore, detailsStore: detailsStore,
                               categoryStore: categoryStore, onCreateCategory: { beginNewCategory(including: app) })
                        .id(app.id)
                } else {
                    EmptyState(symbol: "note.text", title: preferences.text("detail.empty"),
                               message: preferences.text("detail.empty.help"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 520)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: onSearch) {
                    Label(preferences.text("menu.search"), systemImage: "magnifyingglass")
                }
                .help(preferences.text("menu.search") + "  ⌃⌥N")
                Button(action: onSettings) {
                    Label(preferences.text("settings.open"), systemImage: "gearshape")
                }
                .help(preferences.text("settings.open") + "  ⌘,")
            }
        }
        .frame(minWidth: 880, minHeight: 580)
        .onAppear {
            library.scanIfNeeded()
            reconcileSelection()
        }
        .onChange(of: filter) { _, _ in
            query = ""
            selection = filtered.first?.id
        }
        .onChange(of: query) { _, _ in reconcileSelection() }
        .onChange(of: library.apps) { _, _ in reconcileSelection() }
        .onChange(of: categoryStore.memberships) { _, _ in reconcileSelection() }
        .onChange(of: categoryStore.categories) { _, _ in
            if activeFilter == nil && activeCustomCategory == nil { filter = LibraryFilter.all.rawValue }
            reconcileSelection()
        }
        .sheet(isPresented: $showingNewCategory) {
            CategoryEditor(store: categoryStore, including: newCategoryApp) { category in
                filter = "custom:\(category.id.uuidString)"
            }
        }
        .sheet(item: $categoryEditor) { category in
            CategoryEditor(store: categoryStore, category: category)
        }
        .sheet(item: $managingCategory) { category in
            CategoryAppsEditor(store: categoryStore, library: library, category: category)
        }
        .alert(preferences.text("category.error"), isPresented: Binding(
            get: { categoryStore.errorKey != nil && !showingNewCategory && categoryEditor == nil && managingCategory == nil },
            set: { if !$0 { categoryStore.errorKey = nil } })) {
            Button(preferences.text("info.ok"), role: .cancel) { categoryStore.errorKey = nil }
        } message: {
            Text(preferences.text(categoryStore.errorKey ?? "category.saveFailed"))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $filter) {
                Section(preferences.text("library.title")) {
                    filterRow(.all)
                    filterRow(.noted)
                }
                Section(preferences.text("library.sources")) {
                    filterRow(.system)
                    filterRow(.appStore)
                    filterRow(.downloaded)
                }
                Section(preferences.text("category.title")) {
                    ForEach(categoryStore.categories) { category in customCategoryRow(category) }
                    Button { beginNewCategory() } label: {
                        Label(preferences.text("category.new"), systemImage: "plus")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 4)
                    .accessibilityIdentifier("category.new")
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "note.text")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AppNotes").font(.headline)
                        Text(preferences.text("app.title")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            Divider()
            Button(action: onSearch) {
                HStack {
                    Label(preferences.text("menu.search"), systemImage: "magnifyingglass")
                    Spacer(minLength: 4)
                    Text("⌃⌥N").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .navigationTitle(preferences.text("app.title"))
    }

    private func filterRow(_ item: LibraryFilter) -> some View {
        HStack {
            Label {
                Text(preferences.text(item.titleKey))
            } icon: {
                if filter == item.rawValue {
                    Image(systemName: item.symbol).foregroundStyle(.primary)
                } else {
                    Image(systemName: item.symbol).foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 4)
            Text(library.apps.filter { item.contains($0, store: store) }.count, format: .number)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .listItemTint(.accentColor)
        .tag(item.rawValue)
    }

    private func customCategoryRow(_ category: CustomAppCategory) -> some View {
        let selected = filter == "custom:\(category.id.uuidString)"
        return HStack {
            Image(systemName: "folder").foregroundStyle(selected ? Color.primary : Color.accentColor)
            Text(category.name).lineLimit(1)
            Spacer(minLength: 4)
            Text(categoryStore.apps(in: category, from: library.apps).count, format: .number)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 3).tag("custom:\(category.id.uuidString)")
        .help(category.name)
        .contextMenu {
            Button(preferences.text("category.manage")) { managingCategory = category }
            Button(preferences.text("category.rename")) { categoryEditor = category }
            Divider()
            Button(preferences.text("category.delete"), role: .destructive) { categoryStore.delete(category) }
                .help(preferences.text("category.deleteHelp"))
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(activeCustomCategory?.name ?? preferences.text(activeFilter?.titleKey ?? "library.all"))
                        .font(.title3.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 6)
                    Text(preferences.text("library.count", filtered.count))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                }
                if let category = activeCustomCategory {
                    HStack {
                        Button { managingCategory = category } label: {
                            Label(preferences.text("category.manage"), systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("category.manage")
                        Spacer(minLength: 6)
                        Menu {
                            Button(preferences.text("category.rename")) { categoryEditor = category }
                            Button(preferences.text("category.delete"), role: .destructive) { categoryStore.delete(category) }
                        } label: {
                            Label(preferences.text("info.more"), systemImage: "ellipsis").labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    .buttonStyle(.borderless).font(.callout)
                }
                SearchField(text: $query, prompt: preferences.text("search.placeholder"))
            }
            .padding(16)
            Divider()
            List(selection: $selection) {
                ForEach(filtered) { app in
                    SidebarRow(app: app, note: store.note(for: app.path),
                               suggestion: suggestionStore.suggestion(for: app.path))
                        .listRowSeparator(.hidden)
                        .tag(app.id)
                        .contextMenu {
                            Button(preferences.text("detail.open")) { app.open() }
                            Button(preferences.text("detail.reveal")) { app.reveal() }
                            Divider()
                            Menu(preferences.text("category.addTo")) {
                                CategoryMembershipItems(app: app, store: categoryStore) { beginNewCategory(including: app) }
                            }
                            if let category = activeCustomCategory {
                                Button(preferences.text("category.remove")) {
                                    categoryStore.setMembership(app, in: category, included: false)
                                }
                            }
                        }
                }
            }
            .listStyle(.inset)
            .accessibilityLabel(preferences.text("library.list"))
            .overlay {
                if library.isScanning && library.apps.isEmpty {
                    ProgressView(preferences.text("library.scanning")).controlSize(.small)
                } else if filtered.isEmpty {
                    listEmptyState
                }
            }
            Divider()
            ManagerBottomBar(isScanning: library.isScanning, apps: library.apps, onReload: library.refresh)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var listEmptyState: some View {
        VStack(spacing: 12) {
            if !query.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: preferences.text("search.noResults"),
                           message: preferences.text("search.tryAgain"), compact: true)
                Button(preferences.text("search.clear")) { query = "" }
            } else if activeFilter == .noted {
                EmptyState(symbol: "square.and.pencil", title: preferences.text("library.noNotes"),
                           message: preferences.text("library.noNotes.help"), compact: true)
                Button(preferences.text("library.browse")) { filter = LibraryFilter.all.rawValue }
            } else if let category = activeCustomCategory {
                EmptyState(symbol: "folder", title: preferences.text("category.empty"),
                           message: preferences.text("category.emptyHelp"), compact: true)
                Button(preferences.text("category.manage")) { managingCategory = category }
                    .buttonStyle(.borderedProminent)
            } else {
                EmptyState(symbol: activeFilter?.symbol ?? "folder", title: preferences.text("library.empty"),
                           message: preferences.text("library.empty.help"), compact: true)
            }
        }
        .padding(16)
    }

    private func reconcileSelection() {
        if let selection, filtered.contains(where: { $0.id == selection }) { return }
        selection = filtered.first?.id
    }

    private func beginNewCategory(including app: AppEntry? = nil) {
        newCategoryApp = app
        showingNewCategory = true
    }
}

// Progress observation stays local so incoming descriptions do not rebuild the navigation.
struct ManagerBottomBar: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject private var progress = FetchProgress.shared
    let isScanning: Bool
    let apps: [AppEntry]
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if progress.isRunning {
                HStack {
                    Text(preferences.text(progress.cancelRequested ? "fetch.cancelling" : "fetch.action"))
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button(preferences.text("fetch.cancel")) { progress.cancelRequested = true }
                        .buttonStyle(.borderless).font(.caption).disabled(progress.cancelRequested)
                }
                ProgressView(value: Double(progress.current), total: Double(max(progress.total, 1)))
                HStack {
                    Text(progress.currentName).lineLimit(1)
                    Spacer()
                    Text(preferences.text("fetch.progress", progress.current, progress.total)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button {
                        Task { await DescriptionFetcher.shared.fetchAll(apps: apps, progress: progress) }
                    } label: {
                        Label(preferences.text("fetch.action"), systemImage: "text.badge.plus")
                    }
                    .help(preferences.text("fetch.help")).disabled(apps.isEmpty || isScanning)
                    Spacer(minLength: 4)
                    Button(action: onReload) {
                        Label(preferences.text("library.scan"), systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .help(preferences.text("library.scan")).disabled(isScanning)
                }
                .buttonStyle(.borderless).font(.callout)
                if isScanning {
                    Text(preferences.text("library.scanning")).font(.caption).foregroundStyle(.secondary)
                } else if progress.found > 0 {
                    Text(preferences.text("fetch.found", progress.found)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }
}

struct NoteEditorView: View {
    @EnvironmentObject private var preferences: AppPreferences
    let app: AppEntry
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var suggestionStore = SuggestionStore.shared
    @FocusState private var isEditing: Bool
    private var note: String { store.note(for: app.path) }
    private var binding: Binding<String> {
        Binding(get: { note }, set: { store.set($0, for: app.path) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                editor
                if note.isEmpty, let suggestion = suggestionStore.suggestion(for: app.path) {
                    suggestionCard(suggestion)
                }
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(preferences.text("detail.note"), systemImage: "square.and.pencil").font(.headline)
                Spacer()
                Text(preferences.text("detail.characters", note.count))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: binding)
                    .font(.system(size: 14)).lineSpacing(5)
                    .scrollContentBackground(.hidden).padding(12).focused($isEditing)
                    .accessibilityLabel(preferences.text("detail.note"))
                if note.isEmpty {
                    Text(preferences.text("detail.placeholder"))
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(.tertiary)
                        .padding(.horizontal, 17).padding(.vertical, 12)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 210, idealHeight: 250)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isEditing ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.1),
                                  lineWidth: isEditing ? 2 : 1)
                    .allowsHitTesting(false)
            }
            Label(preferences.text("detail.autosave"), systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func suggestionCard(_ suggestion: AppSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(preferences.text(suggestion.source == "brew" ? "suggestion.brew" : "suggestion.appstore"),
                      systemImage: "text.quote").font(.callout.weight(.medium))
                Spacer(minLength: 0)
                if suggestion.score < 0.85 {
                    Text(preferences.text("suggestion.mismatch")).font(.caption).foregroundStyle(.orange)
                }
            }
            Text(suggestion.text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Button(preferences.text("suggestion.use")) { store.set(suggestion.text, for: app.path) }
                Button(preferences.text("suggestion.ignore")) { suggestionStore.ignore(app.path) }
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            if !suggestion.seller.isEmpty {
                Text(suggestion.seller).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
        }
    }

}

struct SidebarRow: View {
    @EnvironmentObject private var preferences: AppPreferences
    let app: AppEntry
    let note: String
    let suggestion: AppSuggestion?

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: app, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                Text(note.isEmpty ? (suggestion?.text ?? preferences.text("detail.noNote")) : note)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).frame(height: 15, alignment: .top)
            }
            Spacer(minLength: 0)
            if !note.isEmpty {
                Image(systemName: "note.text").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}
