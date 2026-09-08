import SwiftUI

struct CategoryMembershipItems: View {
    @EnvironmentObject private var preferences: AppPreferences
    let app: AppEntry
    @ObservedObject var store: CustomCategoryStore
    let onCreate: () -> Void

    var body: some View {
        ForEach(store.categories) { category in
            Toggle(category.name, isOn: Binding(
                get: { store.contains(app, in: category) },
                set: { store.setMembership(app, in: category, included: $0) }))
        }
        if !store.categories.isEmpty { Divider() }
        Button(action: onCreate) {
            Label(preferences.text("category.new"), systemImage: "folder.badge.plus")
        }
    }
}

struct CategoryEditor: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CustomCategoryStore
    let category: CustomAppCategory?
    let including: AppEntry?
    let onCreate: (CustomAppCategory) -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(store: CustomCategoryStore, category: CustomAppCategory? = nil, including: AppEntry? = nil,
         onCreate: @escaping (CustomAppCategory) -> Void = { _ in }) {
        self.store = store
        self.category = category
        self.including = including
        self.onCreate = onCreate
        _name = State(initialValue: category?.name ?? "")
    }

    private var validation: String? { store.nameError(name, excluding: category?.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                CategoryEmblem()
                VStack(alignment: .leading, spacing: 4) {
                    Text(preferences.text(category == nil ? "category.new" : "category.rename"))
                        .font(.title3.weight(.semibold))
                    Text(preferences.text("category.editorHelp"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(preferences.text("category.name")).font(.callout.weight(.medium))
                TextField(preferences.text("category.namePlaceholder"), text: $name)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityLabel(preferences.text("category.name"))
                    .accessibilityIdentifier("category.name")
                    .onSubmit(save)
                if let validation, !name.isEmpty {
                    Text(preferences.text(validation)).font(.caption).foregroundStyle(.secondary)
                }
                if let including {
                    Label(preferences.text("category.includeApp", including.name), systemImage: "plus.app")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = store.errorKey {
                    Text(preferences.text(error)).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(preferences.text("fetch.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(preferences.text(category == nil ? "category.create" : "category.save"), action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(validation != nil).accessibilityIdentifier("category.save")
            }
        }
        .padding(24).frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
    }

    private func save() {
        guard validation == nil else { return }
        if let category {
            if store.rename(category, to: name) { dismiss() }
        } else if let created = store.create(name: name, including: including) {
            onCreate(created)
            dismiss()
        }
    }
}

struct CategoryAppsEditor: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CustomCategoryStore
    @ObservedObject var library: AppLibrary
    let category: CustomAppCategory
    @State private var query = ""
    @State private var selectedPaths: Set<String>

    init(store: CustomCategoryStore, library: AppLibrary, category: CustomAppCategory) {
        self.store = store
        self.library = library
        self.category = category
        _selectedPaths = State(initialValue: Set(store.memberships.filter { $0.value.contains(category.id) }.keys))
    }

    private var visibleApps: [AppEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.apps.filter { term.isEmpty || $0.matches(term, note: "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    CategoryEmblem()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.name).font(.title3.weight(.semibold)).lineLimit(2)
                        Text(preferences.text("category.manageHelp"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                SearchField(text: $query, prompt: preferences.text("category.search"))
            }
            .padding(24)
            Divider()
            List {
                ForEach(visibleApps) { app in
                    Toggle(isOn: Binding(
                        get: { selectedPaths.contains(app.path) },
                        set: { included in
                            if included { selectedPaths.insert(app.path) }
                            else { selectedPaths.remove(app.path) }
                        })) {
                        HStack(spacing: 10) {
                            AppIcon(app: app, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(app.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 6).padding(.vertical, 5)
                    }
                    .toggleStyle(.checkbox).help(app.path)
                    .accessibilityLabel(app.name)
                    .accessibilityIdentifier("category.app." + app.path)
                }
            }
            .listStyle(.inset)
            .overlay {
                if visibleApps.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: preferences.text("search.noResults"),
                               message: preferences.text("category.searchHelp"), compact: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let error = store.errorKey {
                    Text(preferences.text(error)).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text(preferences.text("category.selectedCount", library.apps.filter { selectedPaths.contains($0.path) }.count))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button(preferences.text("fetch.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(preferences.text("category.save")) {
                        if store.update(category, apps: library.apps, selectedPaths: selectedPaths) { dismiss() }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("category.saveApps")
                }
            }
            .padding(20)
        }
        .frame(width: 540, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CategoryEmblem: View {
    var body: some View {
        Image(systemName: "folder")
            .font(.system(size: 22, weight: .medium)).foregroundStyle(Color.accentColor)
            .frame(width: 48, height: 48)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}
