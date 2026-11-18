import SwiftUI
import AppKit

enum Radius {
    static let control: CGFloat = 7
    static let group: CGFloat = 10
    static let surface: CGFloat = 12

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

enum AppSurface {
    // Resolve the surface palette against the hosting window so
    // System / Light / Dark switches update every window without rebuilding it.
    static let canvas = adaptive(0xf4f4f6, 0x1a1a1e)
    static let card = adaptive(0xffffff, 0x232327)
    static let inset = adaptive(0xf9f9fb, 0x1f1f23)
    static let pill = adaptive(0xf1f1f4, 0x2d2d33)
    static let hover = adaptive(0xe9e9ee, 0x36363d)
    static let line = adaptive(0xe3e3e8, 0x333339)
    static let subtleLine = adaptive(0xececf0, 0x2c2c32)
    static let ink = adaptive(0x1c1c21, 0xededf1)
    static let inverse = adaptive(0xffffff, 0x1a1a1e)
    static let secondary = adaptive(0x63636b, 0xa1a1aa)
    static let accent = adaptive(0x4f46e5, 0xa5b4fc)
    static let success = adaptive(0x16804a, 0x6fd99b)
    static let warning = adaptive(0x9a4b09, 0xf2b544)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

/// Shared spacing and surfaces for detail pages and editors.
enum PageStyle {
    static let inset: CGFloat = 24
    static let spacing: CGFloat = 20
    static let width: CGFloat = 760
}

struct DetailCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .elevatedCard()
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(AppSurface.secondary)
                .frame(width: 28, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct AppIcon: View {
    let app: AppEntry
    let size: CGFloat
    var body: some View {
        artwork
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var artwork: some View {
        if app.origin == .manual {
            if let url = URL.web(app.artworkURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase { image.resizable().interpolation(.high) }
                    else { placeholder }
                }
            } else { placeholder }
        } else {
            Image(nsImage: IconCache.icon(for: app.path)).resizable().interpolation(.high)
        }
    }

    private var placeholder: some View {
        Image(systemName: "app.fill")
            .font(.system(size: size * 0.62))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}

struct IconButtonChrome: ViewModifier {
    var tint: Color = .primary
    var isPressed = false
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fillOpacity: Double {
        guard isEnabled else { return 0 }
        if isPressed { return 0.16 }
        if isHovering { return 0.10 }
        return 0
    }

    private var strokeOpacity: Double {
        guard isEnabled, isHovering || isPressed else { return 0 }
        return isPressed ? 0.22 : 0.16
    }

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? tint : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(fillOpacity), in: Radius.shape(Radius.control))
            .overlay {
                Radius.shape(Radius.control)
                    .strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: 1)
            }
            .contentShape(Radius.shape(Radius.control))
            .onHover { isHovering = $0 && isEnabled }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovering = false }
            }
            .animation(Motion.feedback(reduced: reduceMotion), value: isHovering)
            .animation(Motion.feedback(reduced: reduceMotion), value: isPressed)
            .animation(Motion.feedback(reduced: reduceMotion), value: isEnabled)
    }
}

extension View {
    func iconButtonChrome(tint: Color = .primary, isPressed: Bool = false) -> some View {
        modifier(IconButtonChrome(tint: tint, isPressed: isPressed))
    }
}

struct IconButtonStyle: PrimitiveButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.iconButtonChrome(tint: tint)
        }
        .buttonStyle(.borderless)
    }
}

/// Neutral hover and press for controls that otherwise look like static text.
struct QuietAffordance: ViewModifier {
    var cornerRadius: CGFloat = Radius.control
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @GestureState private var pressed = false

    func body(content: Content) -> some View {
        content
            .background {
                Radius.shape(cornerRadius)
                    .fill(Color.primary.opacity(pressed ? 0.08 : hovering ? 0.04 : 0))
            }
            .animation(Motion.feedback(reduced: reduceMotion), value: hovering)
            .animation(Motion.feedback(reduced: reduceMotion), value: pressed)
            .onHover { hovering = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in
                state = true
            })
    }
}

extension View {
    func quietAffordance(cornerRadius: CGFloat = Radius.control) -> some View {
        modifier(QuietAffordance(cornerRadius: cornerRadius))
    }
}

struct QuietPressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Radius.control

    func makeBody(configuration: Configuration) -> some View {
        QuietPressButton(cornerRadius: cornerRadius, isPressed: configuration.isPressed, label: configuration.label)
    }
}

private struct QuietPressButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var cornerRadius: CGFloat
    var isPressed: Bool
    var label: ButtonStyleConfiguration.Label

    var body: some View {
        label
            .background {
                Radius.shape(cornerRadius)
                    .fill(Color.primary.opacity(isPressed ? 0.08 : hovering ? 0.04 : 0))
            }
            .animation(Motion.feedback(reduced: reduceMotion), value: hovering)
            .animation(Motion.feedback(reduced: reduceMotion), value: isPressed)
            .onHover { hovering = $0 }
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
                .font(.system(size: compact ? 22 : 30, weight: .light))
                .foregroundStyle(AppSurface.secondary)
                .frame(width: compact ? 44 : 60, height: compact ? 44 : 60)
                .background(AppSurface.pill, in: Radius.shape(Radius.surface))
                .accessibilityHidden(true)
            Text(title).font(.system(size: compact ? 14 : 18, weight: .semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
                // Respect the proposed height: fixedSize(vertical: true) can inflate
                // NavigationSplitView's minimum height during narrow-width measurement.
                .multilineTextAlignment(.center)
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
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8)
        .fieldChrome(focused: isFocused)
    }
}

struct FieldChrome: ViewModifier {
    var focused: Bool
    var radius: CGFloat = Radius.control
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(AppSurface.card, in: Radius.shape(radius))
            .overlay {
                FieldFocusRing(focused: focused, radius: radius)
                    .animation(Motion.feedback(reduced: reduceMotion), value: focused)
            }
    }
}

private struct FieldFocusRing: View {
    var focused: Bool
    var radius: CGFloat

    var body: some View {
        ZStack {
            Radius.shape(radius)
                .strokeBorder(focused ? AppSurface.accent : AppSurface.line, lineWidth: 1)
            Radius.shape(radius)
                .inset(by: -1.5)
                .stroke(AppSurface.accent.opacity(focused ? 0.20 : 0), lineWidth: 3)
        }
        .allowsHitTesting(false)
    }
}

struct ElevatedCard: ViewModifier {
    var radius: CGFloat = Radius.surface

    func body(content: Content) -> some View {
        content
            .background(AppSurface.card, in: Radius.shape(radius))
            .overlay {
                Radius.shape(radius)
                    .strokeBorder(AppSurface.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// Graphite primary action and quiet, bordered secondary action. Retains Button's
/// native activation, keyboard shortcuts and accessibility semantics.
struct AppActionStyle: PrimitiveButtonStyle {
    enum Emphasis { case secondary, primary }
    var emphasis: Emphasis = .secondary

    init(_ emphasis: Emphasis = .secondary) { self.emphasis = emphasis }

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if emphasis == .primary {
                Button(configuration).buttonStyle(.borderedProminent)
            } else {
                Button(configuration).buttonStyle(.bordered)
            }
        }
        .tint(AppSurface.ink)
        .controlSize(.regular)
        .font(.system(size: 12, weight: .medium))
    }
}

struct CountBadge: View {
    let count: Int
    var emphasized = false
    var body: some View {
        Text(count, format: .number)
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(emphasized ? AppSurface.inverse : AppSurface.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(emphasized ? AppSurface.ink : AppSurface.pill, in: Capsule())
    }
}

extension View {
    func fieldChrome(focused: Bool, radius: CGFloat = Radius.control) -> some View {
        modifier(FieldChrome(focused: focused, radius: radius))
    }

    func elevatedCard(radius: CGFloat = Radius.surface) -> some View {
        modifier(ElevatedCard(radius: radius))
    }
}

struct ShortcutHint: View {
    let keys: String
    let title: String
    var body: some View {
        HStack(spacing: 5) {
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(.quaternary, in: Radius.shape(Radius.control))
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
    func open() {
        if origin == .manual, let id = appStoreID,
           let url = URL(string: "https://apps.apple.com/\(storeCountryCode)/app/id\(id)") {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    func reveal() {
        guard origin != .manual else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
