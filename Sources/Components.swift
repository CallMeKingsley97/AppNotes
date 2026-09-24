import SwiftUI
import AppKit

enum Radius {
    static let control: CGFloat = 6
    static let group: CGFloat = 10
    static let surface: CGFloat = 14

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

enum AppSurface {
    static let card = Color(nsColor: NSColor(name: nil, dynamicProvider: cardColor))

    /// `controlBackgroundColor` is white above the window in light mode, but darker than it in dark mode.
    private static func cardColor(_ appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.controlBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            let window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
            let control = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? .controlBackgroundColor
            if luminance(control) + 0.01 >= luminance(window) {
                resolved = control
            } else {
                resolved = window.blended(withFraction: 0.08, of: .white) ?? window
            }
        }
        return resolved
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
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
        if app.origin == .manual, let url = URL.web(app.artworkURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().interpolation(.high)
                default:
                    Image(systemName: "app.fill")
                        .font(.system(size: size * 0.62))
                        .foregroundStyle(.secondary)
                        .frame(width: size, height: size)
                }
            }
        } else {
            Image(nsImage: IconCache.icon(for: app.path)).resizable().interpolation(.high)
        }
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
        return 0.06
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
            .frame(width: 28, height: 28)
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

struct IconButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .iconButtonChrome(tint: tint, isPressed: configuration.isPressed)
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
            .scaleEffect(reduceMotion || !pressed ? 1 : 0.985)
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
            .scaleEffect(reduceMotion || !isPressed ? 1 : 0.985)
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
        .fieldChrome(focused: isFocused)
    }
}

struct FieldChrome: ViewModifier {
    var focused: Bool
    var radius: CGFloat = Radius.control
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: Radius.shape(radius))
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
                .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
            Radius.shape(radius)
                .inset(by: -1.5)
                .stroke(Color.accentColor.opacity(focused ? 0.28 : 0), lineWidth: 3)
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
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
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
