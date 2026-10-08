import Foundation
import Observation

@MainActor
@Observable
public final class AppPreferences {
    public enum CaptureDefault: String, CaseIterable {
        case uniques, all
    }

    public enum OrganisationDefault: String, CaseIterable {
        case chronology, byScreen
    }

    public enum ScreenExportLayout: String, CaseIterable {
        case singleFolder, folders
    }

    enum Keys {
        static let captures = "defaultCaptures"
        static let organisation = "defaultOrganisation"
        static let exportLayout = "screenExportLayout"
    }

    private let defaults: UserDefaults

    public var captureDefault: CaptureDefault {
        didSet { defaults.set(captureDefault.rawValue, forKey: Keys.captures) }
    }
    public var organisationDefault: OrganisationDefault {
        didSet { defaults.set(organisationDefault.rawValue, forKey: Keys.organisation) }
    }
    public var screenExportLayout: ScreenExportLayout {
        didSet { defaults.set(screenExportLayout.rawValue, forKey: Keys.exportLayout) }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        captureDefault = (defaults.object(forKey: Keys.captures) as? String)
            .flatMap(CaptureDefault.init(rawValue:)) ?? .uniques
        organisationDefault = (defaults.object(forKey: Keys.organisation) as? String)
            .flatMap(OrganisationDefault.init(rawValue:)) ?? .chronology
        screenExportLayout = (defaults.object(forKey: Keys.exportLayout) as? String)
            .flatMap(ScreenExportLayout.init(rawValue:)) ?? .singleFolder
    }
}
