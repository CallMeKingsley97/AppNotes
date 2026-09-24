import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.1), in: Radius.shape(Radius.surface))
                VStack(alignment: .leading, spacing: 5) {
                    Text(preferences.text("settings.title")).font(.title2.weight(.semibold))
                    Text(preferences.text("settings.personalize")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 6)

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            ForEach(AppAppearance.allCases) { appearance in
                                appearanceOption(appearance)
                            }
                        }
                        Text(preferences.text("settings.appearance.help"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label(preferences.text("settings.appearance"), systemImage: "circle.lefthalf.filled")
                }
                Section {
                    Picker(preferences.text("settings.language"), selection: $preferences.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(preferences.text("language.\(language.rawValue)")).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(preferences.text("settings.language.help"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Label(preferences.text("settings.language"), systemImage: "globe")
                }
                Section {
                    Toggle(isOn: $preferences.hudEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preferences.text("settings.hud"))
                            Text(preferences.text("settings.hud.help"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    LabeledContent(preferences.text("settings.shortcut")) {
                        Text("⌃⌥N").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                } header: {
                    Label(preferences.text("settings.behavior"), systemImage: "keyboard")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Text(preferences.text("settings.saved"))
                .font(.caption).foregroundStyle(.tertiary).padding(.bottom, 18)
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
