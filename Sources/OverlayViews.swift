import SwiftUI
import AppKit

struct SearchOverlayView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var library = AppLibrary.shared
    let onClose: () -> Void
    var focusSession = 0
    @State private var query = ""
    @State private var highlighted = 0
    @State private var keyboardNavigation = false
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
                        .onChange(of: highlighted) { _, index in
                            guard keyboardNavigation else {
                                proxy.scrollTo(index)
                                return
                            }
                            keyboardNavigation = false
                            withAnimation(Motion.scroll(reduced: reduceMotion)) {
                                proxy.scrollTo(index)
                            }
                        }
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
        .background(.regularMaterial, in: Radius.shape(Radius.surface))
        .overlay {
            Radius.shape(Radius.surface).strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(Radius.shape(Radius.surface))
        .onAppear {
            library.scanIfNeeded()
            isFocused = true
        }
        .onChange(of: focusSession) { _, _ in isFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onChange(of: results.map(\.id)) { _, _ in highlighted = min(highlighted, max(results.count - 1, 0)) }
        .onExitCommand(perform: onClose)
        .onMoveCommand { direction in
            let next: Int
            switch direction {
            case .down: next = min(highlighted + 1, max(results.count - 1, 0))
            case .up: next = max(highlighted - 1, 0)
            default: return
            }
            guard next != highlighted else { return }
            keyboardNavigation = true
            highlighted = next
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
                    in: Radius.shape(Radius.group))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

final class PanelPresence: ObservableObject {
    @Published var shown = false
    @Published var session = 0
}

struct SearchPanelRoot: View {
    @ObservedObject var presence: PanelPresence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onClose: () -> Void

    var body: some View {
        SearchOverlayView(onClose: onClose, focusSession: presence.session)
            .scaleEffect(reduceMotion || presence.shown ? 1 : 0.985)
            .animation(Motion.panel(reduced: reduceMotion), value: presence.shown)
    }
}

final class HUDContent: ObservableObject {
    @Published var appName: String
    @Published var note: String
    @Published var appPath: String?
    @Published var presented: Bool

    init(appName: String = "", note: String = "", appPath: String? = nil, presented: Bool = true) {
        self.appName = appName
        self.note = note
        self.appPath = appPath
        self.presented = presented
    }

    var identity: String { appName + "\u{0}" + note + "\u{0}" + (appPath ?? "") }
}

struct HUDView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var content: HUDContent

    init(content: HUDContent) {
        self.content = content
    }

    init(appName: String, note: String, appPath: String?) {
        self.content = HUDContent(appName: appName, note: note, appPath: appPath, presented: true)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let appPath = content.appPath {
                Image(nsImage: IconCache.icon(for: appPath)).resizable().frame(width: 36, height: 36)
            } else {
                Image(systemName: "note.text").font(.title2).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(content.appName).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(preferences.text("hud.note")).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                }
                Text(content.note).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(content.identity)
        .transition(.opacity)
        .padding(16).frame(width: 390, alignment: .leading)
        .background(.regularMaterial, in: Radius.shape(Radius.surface))
        .overlay {
            Radius.shape(Radius.surface).strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .motionCrossfade(id: content.identity)
        .scaleEffect(reduceMotion || content.presented ? 1 : 0.985)
        .animation(Motion.panel(reduced: reduceMotion), value: content.presented)
    }
}
