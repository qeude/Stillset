import SwiftUI

public struct SettingsView: View {
    @Bindable private var preferences: AppPreferences

    public init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    public var body: some View {
        Form {
            Section("Par défaut pour la prochaine session") {
                Picker("Captures", selection: $preferences.captureDefault) {
                    Text("Uniques").tag(AppPreferences.CaptureDefault.uniques)
                    Text("Toutes").tag(AppPreferences.CaptureDefault.all)
                }
                Picker("Organisation", selection: $preferences.organisationDefault) {
                    Text("Chronologie").tag(AppPreferences.OrganisationDefault.chronology)
                    Text("Par écran").tag(AppPreferences.OrganisationDefault.byScreen)
                }
            }

            Section {
                Picker("Export par écran", selection: $preferences.screenExportLayout) {
                    Text("Un seul dossier").tag(AppPreferences.ScreenExportLayout.singleFolder)
                    Text("Un dossier par écran").tag(AppPreferences.ScreenExportLayout.folders)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
    }
}
