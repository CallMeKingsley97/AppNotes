import SwiftUI
import AppKit

struct AppIcon: View {
    let app: AppEntry
    let size: CGFloat
    var body: some View {
        Image(nsImage: IconCache.icon(for: app.path))
            .resizable().interpolation(.high).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct IconButtonChrome: ViewModifier {
    var tint: Color = .accentColor
    var isPressed = false
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? tint : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(isPressed ? 0.16 : isHovering ? 0.12 : 0.07))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tint.opacity(isPressed ? 0.28 : isHovering ? 0.22 : 0.12), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { isHovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.18), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

extension View {
    func iconButtonChrome(tint: Color = .accentColor, isPressed: Bool = false) -> some View {
        modifier(IconButtonChrome(tint: tint, isPressed: isPressed))
    }
}

struct IconButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .iconButtonChrome(tint: tint, isPressed: configuration.isPressed)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var compact = false
    var body: some View {
        VStack(spacing: compact ? 10 : 16) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 28 : 42, weight: .light))
                .foregroundStyle(.tertiary).padding(.bottom, 4)
            Text(title).font(compact ? .headline : .title2.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 310)
        }
        .padding(compact ? 8 : 32)
    }
}

struct SearchField: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused($isFocused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help(preferences.text("search.clear"))
                .accessibilityLabel(preferences.text("search.clear"))
            }
        }
        .font(.callout).padding(.horizontal, 9).padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 2)
        }
    }
}

struct ShortcutHint: View {
    let keys: String
    let title: String
    var body: some View {
        HStack(spacing: 5) {
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(title).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

extension AppEntry {
    func matches(_ query: String, note: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || fileName.localizedCaseInsensitiveContains(query)
            || (bundleID ?? "").localizedCaseInsensitiveContains(query)
            || note.localizedCaseInsensitiveContains(query)
    }
    func open() { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
