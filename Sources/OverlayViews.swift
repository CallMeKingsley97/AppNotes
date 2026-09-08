import SwiftUI
import AppKit

struct SearchOverlayView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var library = AppLibrary.shared
    let onClose: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    private var results: [AppEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(library.apps.filter {
            term.isEmpty ? !store.note(for: $0.path).isEmpty : $0.matches(term, note: store.note(for: $0.path))
        }.prefix(40))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title2.weight(.regular)).foregroundStyle(.secondary)
                TextField(preferences.text("search.placeholder"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 20))
                    .focused($isFocused).onSubmit { openHighlighted() }
                    .accessibilityLabel(preferences.text("search.placeholder"))
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).help(preferences.text("search.close"))
                .accessibilityLabel(preferences.text("search.close"))
            }
            .padding(20)
            Divider()
            if results.isEmpty {
                EmptyState(symbol: query.isEmpty ? "note.text" : "magnifyingglass",
                           title: preferences.text(query.isEmpty ? "search.empty" : "search.noResults"),
                           message: preferences.text(query.isEmpty ? "search.empty.help" : "search.tryAgain"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(preferences.text(query.isEmpty ? "search.saved" : "search.results"))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                                    ResultRow(app: app, note: store.note(for: app.path), isHighlighted: index == highlighted) {
                                        highlighted = index
                                        openHighlighted()
                                    }
                                    .id(index)
                                }
                            }
                            .padding(.horizontal, 10).padding(.bottom, 10)
                        }
                        .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
                        .onChange(of: query) { _, _ in proxy.scrollTo(0, anchor: .top) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 18) {
                ShortcutHint(keys: "↑ ↓", title: preferences.text("search.navigate"))
                ShortcutHint(keys: "↵", title: preferences.text("search.open"))
                Spacer()
                ShortcutHint(keys: "esc", title: preferences.text("search.close"))
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .frame(width: 580, height: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear {
            library.scanIfNeeded()
            isFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onChange(of: results.map(\.id)) { _, _ in highlighted = min(highlighted, max(results.count - 1, 0)) }
        .onExitCommand(perform: onClose)
        .onMoveCommand { direction in
            switch direction {
            case .down: highlighted = min(highlighted + 1, max(results.count - 1, 0))
            case .up: highlighted = max(highlighted - 1, 0)
            default: break
            }
        }
    }

    private func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        let app = results[highlighted]
        onClose()
        app.open()
    }
}

struct ResultRow: View {
    @EnvironmentObject private var preferences: AppPreferences
    let app: AppEntry
    let note: String
    let isHighlighted: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppIcon(app: app, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(note.isEmpty ? preferences.text("detail.noNote") : note)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if isHighlighted {
                    Image(systemName: "return").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHighlighted ? Color.accentColor.opacity(0.14) : (isHovered ? Color.primary.opacity(0.04) : .clear),
                    in: RoundedRectangle(cornerRadius: 9))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

struct HUDView: View {
    @EnvironmentObject private var preferences: AppPreferences
    let appName: String
    let note: String
    let appPath: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let appPath {
                Image(nsImage: IconCache.icon(for: appPath)).resizable().frame(width: 36, height: 36)
            } else {
                Image(systemName: "note.text").font(.title2).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(appName).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(preferences.text("hud.note")).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                }
                Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 390, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
