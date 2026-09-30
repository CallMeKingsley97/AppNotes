import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var monitor = PriceMonitorStore.shared
    var onManageWatches: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageStyle.spacing) {
                PageHeading(title: preferences.text("settings.title"),
                    subtitle: preferences.text("settings.personalize"), symbol: "slider.horizontal.3")
                DetailCard {
                    Label(preferences.text("settings.appearance"), systemImage: "circle.lefthalf.filled").font(.headline)
                    HStack(spacing: 12) {
                        ForEach(AppAppearance.allCases) { appearance in appearanceOption(appearance) }
                    }
                    Text(preferences.text("settings.appearance.help")).font(.caption).foregroundStyle(.secondary)
                }
                DetailCard {
                    HStack {
                        Label(preferences.text("settings.language"), systemImage: "globe").font(.headline)
                        Spacer()
                        Picker(preferences.text("settings.language"), selection: $preferences.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(preferences.text("language.\(language.rawValue)")).tag(language)
                            }
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    Text(preferences.text("settings.language.help"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DetailCard {
                    Label(preferences.text("monitor.title"), systemImage: "bell").font(.headline)
                    Toggle(preferences.text("monitor.automatic"), isOn: Binding(
                        get: { monitor.state.automaticChecks },
                        set: { enabled in Task { await monitor.setAutomaticChecks(enabled) } }
                    )).toggleStyle(.switch).disabled(!monitor.writable)
                    Text(preferences.text("monitor.runtime"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(preferences.text("monitor.watches"), action: onManageWatches).buttonStyle(.bordered)
                    MonitorFeedback(monitor: monitor)
                }
                DetailCard {
                    Label(preferences.text("settings.behavior"), systemImage: "keyboard").font(.headline)
                    Toggle(isOn: $preferences.hudEnabled) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preferences.text("settings.hud"))
                            Text(preferences.text("settings.hud.help"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch)
                    Divider()
                    LabeledContent(preferences.text("settings.shortcut")) {
                        Text("⌃⌥N").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Label(preferences.text("settings.saved"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(PageStyle.inset)
        }
        .frame(width: 520, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func appearanceOption(_ appearance: AppAppearance) -> some View {
        let selected = preferences.appearance == appearance
        return Button {
            preferences.appearance = appearance
        } label: {
            VStack(spacing: 9) {
                AppearancePreview(appearance: appearance)
                    .frame(height: 66)
                    .overlay {
                        Radius.shape(Radius.group)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: selected ? 2 : 1)
                    }
                HStack(spacing: 5) {
                    Image(systemName: appearance.symbol)
                    Text(preferences.text("appearance.\(appearance.rawValue)"))
                }
                .font(.callout)
                .foregroundStyle(selected ? Color.accentColor : .primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPressButtonStyle(cornerRadius: Radius.group))
        .accessibilityLabel(preferences.text("appearance.\(appearance.rawValue)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// Fixed colors belong only to these previews: they illustrate the chosen appearance.
private struct AppearancePreview: View {
    let appearance: AppAppearance

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                miniature(dark: appearance == .dark)
                if appearance == .system {
                    miniature(dark: true)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: geometry.size.width / 2)
                        }
                }
            }
        }
        .clipShape(Radius.shape(Radius.group))
        .accessibilityHidden(true)
    }

    private func miniature(dark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in Circle().fill(dark ? .white.opacity(0.3) : .black.opacity(0.2)).frame(width: 4, height: 4) }
                }
                Radius.shape(2).fill(Color.accentColor.opacity(0.7)).frame(height: 6)
                Radius.shape(2).fill(dark ? .white.opacity(0.15) : .black.opacity(0.1)).frame(height: 4)
                Spacer(minLength: 0)
            }
            .padding(8).frame(width: 42)
            .background(dark ? Color(white: 0.19) : Color(white: 0.9))
            VStack(alignment: .leading, spacing: 6) {
                Radius.shape(2).fill(dark ? .white.opacity(0.65) : .black.opacity(0.45)).frame(width: 28, height: 5)
                Radius.shape(2).fill(dark ? .white.opacity(0.12) : .black.opacity(0.07)).frame(height: 22)
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity)
            .background(dark ? Color(white: 0.12) : .white)
        }
    }
}
