import SwiftUI
import MarkViewAppCore

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section(Strings.themeSection) {
                Picker(Strings.appearance, selection: $settings.themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
            }
            Section(Strings.windowSection) {
                Toggle(Strings.restoreLastFile, isOn: $settings.windowRestore)
            }
        }
        .frame(width: 360, height: 120)
        .padding()
    }
}
