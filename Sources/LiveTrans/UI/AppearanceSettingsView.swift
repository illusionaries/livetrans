import SwiftUI

struct AppearanceSettingsView: View {

    @ObservedObject var settings: AppearanceSettings
    @ObservedObject var audio: AudioSettings

    var body: some View {
        Form {
            Section(L10n.t("settings.section.minimal")) {
                Toggle(L10n.t("settings.material"), isOn: $settings.useMaterial)

                Text(L10n.t("settings.material_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                sliderRow(
                    L10n.t("settings.opacity"),
                    value: $settings.backgroundOpacity,
                    range: 0...0.85
                ) {
                    String(format: L10n.t("settings.percent"), Int(($0 * 100).rounded()))
                }

                Text(L10n.t("settings.opacity_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                sliderRow(
                    L10n.t("settings.height"),
                    value: $settings.height,
                    range: 120...360
                ) {
                    String(format: L10n.t("settings.pt_int"), Int($0.rounded()))
                }

                sliderRow(
                    L10n.t("settings.width"),
                    value: $settings.width,
                    range: 460...1200
                ) {
                    String(format: L10n.t("settings.pt_int"), Int($0.rounded()))
                }

                Picker(L10n.t("settings.lines"), selection: $settings.lineCount) {
                    Text(L10n.t("settings.lines.one")).tag(1)
                    Text(L10n.t("settings.lines.two")).tag(2)
                    Text(L10n.t("settings.lines.three")).tag(3)
                }
                .pickerStyle(.segmented)

                sliderRow(
                    L10n.t("settings.source_font"),
                    value: $settings.sourceFontSize,
                    range: 10...18
                ) {
                    String(format: L10n.t("settings.pt_decimal"), $0)
                }

                sliderRow(
                    L10n.t("settings.translation_font"),
                    value: $settings.translationFontSize,
                    range: 14...28
                ) {
                    String(format: L10n.t("settings.pt_decimal"), $0)
                }
            }

            Section(L10n.t("settings.section.audio")) {
                Toggle(L10n.t("settings.aec"), isOn: $audio.aecEnabled)

                Text(L10n.t("settings.aec_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.section.preview")) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("settings.preview_source"))
                        .font(.system(size: settings.sourceFontSize))
                        .foregroundStyle(.secondary)

                    Text(L10n.t("settings.preview_translation"))
                        .font(.system(size: settings.translationFontSize, weight: .semibold))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        if settings.useMaterial {
                            Rectangle().fill(.ultraThinMaterial)
                        }
                        if settings.backgroundOpacity > 0.001 {
                            Color.black.opacity(settings.backgroundOpacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Section {
                Button(L10n.t("settings.reset")) {
                    settings.reset()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 760)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
