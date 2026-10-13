import SwiftUI

public struct SettingsView: View {
    @Bindable private var preferences: AppPreferences

    public init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    public var body: some View {
        Form {
            Section(LocalizedStringResource("Defaults for the next session", bundle: .atURL(Bundle.module.bundleURL))) {
                Picker(LocalizedStringResource("Screenshots", bundle: .atURL(Bundle.module.bundleURL)), selection: $preferences.captureDefault) {
                    Text("Unique", bundle: .module).tag(AppPreferences.CaptureDefault.uniques)
                    Text("All", bundle: .module).tag(AppPreferences.CaptureDefault.all)
                }
                Picker(LocalizedStringResource("Organization", bundle: .atURL(Bundle.module.bundleURL)), selection: $preferences.organisationDefault) {
                    Text("Chronology", bundle: .module).tag(AppPreferences.OrganisationDefault.chronology)
                    Text("By screen", bundle: .module).tag(AppPreferences.OrganisationDefault.byScreen)
                }
            }

            Section {
                Picker(LocalizedStringResource("When a session is open", bundle: .atURL(Bundle.module.bundleURL)), selection: $preferences.existingSessionAction) {
                    Text("Ask", bundle: .module).tag(AppPreferences.ExistingSessionAction.ask)
                    Text("Add to this session", bundle: .module).tag(AppPreferences.ExistingSessionAction.add)
                    Text("Start a new session", bundle: .module).tag(AppPreferences.ExistingSessionAction.replace)
                }
            }

            Section {
                Picker(LocalizedStringResource("Export by screen", bundle: .atURL(Bundle.module.bundleURL)), selection: $preferences.screenExportLayout) {
                    Text("One folder", bundle: .module).tag(AppPreferences.ScreenExportLayout.singleFolder)
                    Text("One folder per screen", bundle: .module).tag(AppPreferences.ScreenExportLayout.folders)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .tint(StillsetStyle.accent)
    }
}
