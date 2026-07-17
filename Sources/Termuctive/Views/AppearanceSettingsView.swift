import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Appearance")
                .font(.title2.weight(.semibold))

            settingRow(
                title: "App",
                detail: "Changes the sidebar, bars, menus, and controls."
            ) {
                Picker("App appearance", selection: $settings.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            settingRow(
                title: "Terminals",
                detail: "Changes terminal backgrounds and text independently."
            ) {
                Picker("Terminal appearance", selection: $settings.terminalTheme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func settingRow<Control: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                control()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
