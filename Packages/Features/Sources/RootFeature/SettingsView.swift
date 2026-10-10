import SwiftUI

public struct SettingsView: View {
    @Bindable private var preferences: AppPreferences

    public init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    public var body: some View {
        Form {
            Section(LocalizedStringResource("Defaults for the Next Session", bundle: .atURL(Bundle.module.bundleURL))) {
                Picker(LocalizedStringResource("Screenshots", bundle: .atURL(Bundle.module.bundleURL)), selection: $preferences.captureDefault) {
                    Text("Unique", bundle: .module).tag(AppPreferences.CaptureDefault.uniques)
                    Text("All", bundle: .module).tag(AppPreferences.CaptureDefault.all)
                }
                Picker(LocalizedStringResource("Organization", bundle: .atURL(Bundle.module.bundleURL)), selection: $preferences.organisationDefault) {
                    Text("Chronology", bundle: .module).tag(AppPreferences.OrganisationDefault.chronology)
                    Text("By Screen", bundle: .module).tag(AppPreferences.OrganisationDefault.byScreen)
                }
            }

            Section {
                Picker(LocalizedStringResource("Export by Screen", bundle: .atURL(Bundle.module.bundleURL)), selection: $preferences.screenExportLayout) {
                    Text("One Folder", bundle: .module).tag(AppPreferences.ScreenExportLayout.singleFolder)
                    Text("One Folder per Screen", bundle: .module).tag(AppPreferences.ScreenExportLayout.folders)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .tint(StillsetStyle.accent)
        .background { StillsetBackground() }
    }
}
