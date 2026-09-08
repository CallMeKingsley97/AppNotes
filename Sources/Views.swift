import SwiftUI
import AppKit

struct ManagerView: View {
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var suggestionStore = SuggestionStore.shared
    @State private var query = ""
    @State private var selection: String?
    @State private var category: AppCategory = .appStore
    @State private var apps: [AppEntry] = []
    @State private var isScanning = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let app = selectedApp {
                DetailView(app: app)
            } else {
                VStack(spacing: 8) {
                    Text("选一个应用")
                        .font(.headline)
                    Text("左边点一下，右边就能写备注了")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if apps.isEmpty { reload() }
        }
        .onChange(of: category) { _, newValue in
            let ids = filtered.map(\.id)
            let shouldSelectFirst = selection.map { !ids.contains($0) } ?? true
            if shouldSelectFirst { selection = ids.first }
        }
    }

    private var selectedApp: AppEntry? {
        apps.first { $0.id == selection }
    }

    private var filtered: [AppEntry] {
        let categorized = apps.filter { AppCategory.of($0) == category }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return categorized }
        return categorized.filter { app in
            app.name.localizedCaseInsensitiveContains(q)
                || app.fileName.localizedCaseInsensitiveContains(q)
                || store.note(for: app.path).localizedCaseInsensitiveContains(q)
                || (app.bundleID ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            CategoryTabBar(counts: categoryCounts, selection: $category)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            List(selection: $selection) {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: category.symbolName)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(category.tint.opacity(0.65))
                        Text("没有应用")
                            .font(.subheadline.weight(.medium))
                        Text(query.isEmpty ? "这个分类暂时没有内容" : "换个关键词试试")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    ForEach(filtered) { app in
                        SidebarRow(
                            app: app,
                            note: store.note(for: app.path),
                            suggestion: suggestionStore.suggestion(for: app.path)
                        )
                        .tag(app.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "搜应用名或备注")

            Divider()
            ManagerBottomBar(
                filteredCount: filtered.count,
                totalCount: apps.filter { AppCategory.of($0) == category }.count,
                noteCount: store.count,
                suggestionCount: suggestionStore.count,
                fetchEnabled: !apps.isEmpty,
                onReload: reload,
                onFetch: startFetch
            )
        }
        .frame(minWidth: 260)
        .overlay {
            if isScanning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func startFetch() {
        let list = apps
        Task { await DescriptionFetcher.shared.fetchAll(apps: list, progress: FetchProgress.shared) }
    }

    private func reload() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = AppScanner.scan()
            DispatchQueue.main.async {
                self.apps = scanned
                self.isScanning = false
            }
        }
    }

    private var categoryCounts: [AppCategory: Int] {
        Dictionary(grouping: apps, by: { AppCategory.of($0) })
            .mapValues(\.count)
    }
}

struct CategoryTabBar: View {
    let counts: [AppCategory: Int]
    @Binding var selection: AppCategory

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppCategory.allCases) { item in
                let isSelected = selection == item

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selection = item
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.tabTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(counts[item, default: 0])")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? item.tint.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(isSelected ? item.tint : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(3)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// 进度条独立成一个视图，只让它自己监听 FetchProgress，
// 避免抓取时整个 ManagerView 频繁重建导致 List 的 selection 丢失。
struct ManagerBottomBar: View {
    @ObservedObject var progress = FetchProgress.shared
    let filteredCount: Int
    let totalCount: Int
    let noteCount: Int
    let suggestionCount: Int
    let fetchEnabled: Bool
    let onReload: () -> Void
    let onFetch: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(filteredCount)/\(totalCount) 个应用 · \(noteCount) 条备注 · \(suggestionCount) 条建议")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新扫描已安装的应用")
            }

            if progress.isRunning {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.current), total: Double(max(progress.total, 1)))
                    Text("\(progress.current)/\(progress.total)  \(progress.currentName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("取消") { progress.cancelRequested = true }
                        .font(.caption)
                }
            } else {
                HStack(spacing: 8) {
                    Button("抓取 Mac App Store 简介", action: onFetch)
                        .disabled(!fetchEnabled)
                    Text("按本地 App Store ID 精确查询")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if progress.found > 0 {
                        Text("上次抓到 \(progress.found) 条")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct DetailView: View {
    let app: AppEntry
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var suggestionStore = SuggestionStore.shared

    private var binding: Binding<String> {
        Binding(
            get: { store.note(for: app.path) },
            set: { store.set($0, for: app.path) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: IconCache.icon(for: app.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.title2)
                        if let v = app.version {
                            Text(v).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let b = app.bundleID {
                        Text(b).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(app.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("打开") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
                    }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                    }
                }
                .fixedSize()
            }

            Divider()

            if store.note(for: app.path).isEmpty, let suggestion = suggestionStore.suggestion(for: app.path) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.secondary)
                        Text(suggestion.source == "brew" ? "Homebrew 简介" : "Mac App Store 简介")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !suggestion.seller.isEmpty {
                            Text("· \(suggestion.seller)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if suggestion.score < 0.85 {
                            Text("可能不匹配")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.orange.opacity(0.18))
                                )
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    Text(suggestion.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("采用为备注") { store.set(suggestion.text, for: app.path) }
                        Button("忽略") { suggestionStore.ignore(app.path) }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
            }

            HStack {
                Text("备注").font(.headline)
                Spacer()
                Text("\(store.note(for: app.path).count) 字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: binding)
                    .font(.system(size: 14))
                    .padding(6)
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                if store.note(for: app.path).isEmpty {
                    Text("它是干嘛的？什么时候会用到？随便写点什么……")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            Text("改动会自动保存，⌘W 关窗口即可")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(app.id)
    }
}

struct SearchOverlayView: View {
    @ObservedObject var store = NotesStore.shared
    let apps: [AppEntry]
    let onClose: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    private var results: [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = apps
        guard !q.isEmpty else {
            return Array(base.filter { !store.note(for: $0.path).isEmpty }.prefix(40))
        }
        return Array(
            base.filter { app in
                app.name.localizedCaseInsensitiveContains(q)
                    || app.fileName.localizedCaseInsensitiveContains(q)
                    || store.note(for: app.path).localizedCaseInsensitiveContains(q)
            }.prefix(40))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜应用名或备注", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
                    .onSubmit { openHighlighted() }
                    .onChange(of: query) { _ in highlighted = 0 }
                Text("Esc 关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text("没找到")
                        .foregroundStyle(.secondary)
                    Text("按 Esc 或者点外面关掉")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                            ResultRow(
                                app: app,
                                note: store.note(for: app.path),
                                isHighlighted: index == highlighted
                            ) {
                                highlighted = index
                                openHighlighted()
                            }
                            .onHover { inside in
                                if inside { highlighted = index }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 560)
        .frame(minHeight: 120, maxHeight: 460)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { isFocused = true }
        .onExitCommand(perform: onClose)
        .onMoveCommand { direction in
            switch direction {
            case .down: moveDown()
            case .up: moveUp()
            default: break
            }
        }
    }

    private func moveDown() {
        highlighted = min(highlighted + 1, max(results.count - 1, 0))
    }

    private func moveUp() {
        highlighted = max(highlighted - 1, 0)
    }

    private func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        let app = results[highlighted]
        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
        onClose()
    }
}

struct ResultRow: View {
    let app: AppEntry
    let note: String
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.icon(for: app.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(note.isEmpty ? "还没有备注" : note)
                        .font(.caption)
                        .foregroundStyle(note.isEmpty ? .tertiary : .secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .padding(.horizontal, 6)
    }
}

struct HUDView: View {
    let appName: String
    let note: String

    var body: some View {
        HStack(spacing: 10) {
            Text(appName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

// 列表行：行高永远固定（两行槽位），避免建议陆续出现时整列高度跳变
struct SidebarRow: View {
    let app: AppEntry
    let note: String
    let suggestion: AppSuggestion?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(for: app.path))
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .top)   // 固定槽位高度
            }
            Spacer(minLength: 0)
            CategoryBadge(category: AppCategory.of(app))
        }
        .padding(.vertical, 2)
        .tag(app.id)
    }

    private var secondaryLine: String {
        if !note.isEmpty { return note }
        if let s = suggestion { return s.text }
        return " "   // 占位，保持高度一致
    }
}

struct CategoryBadge: View {
    let category: AppCategory

    var body: some View {
        Image(systemName: category.symbolName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(category.tint)
            .frame(width: 17, height: 17)
            .background(category.tint.opacity(0.14), in: Circle())
            .help(category.title)
    }
}

extension AppCategory {
    var tint: Color {
        switch self {
        case .system: return .gray
        case .appStore: return .blue
        case .downloaded: return .orange
        }
    }
}
