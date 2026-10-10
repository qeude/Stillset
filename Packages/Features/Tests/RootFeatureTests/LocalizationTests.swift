import Foundation
import Testing
@testable import StillsetFeatures

struct LocalizationTests {
    @Test(arguments: ["en", "fr"])
    func interfaceAndExportCounts(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(String(localized: "Drop Your Videos", bundle: bundle)
            == (language == "fr" ? "Déposez vos vidéos" : "Drop Your Videos"))
        #expect(String(localized: "One Folder per Screen", bundle: bundle)
            == (language == "fr" ? "Un dossier par écran" : "One Folder per Screen"))
        let single = 1
        let multiple = 2
        #expect(String(localized: "\(single) screenshots copied.", bundle: bundle)
            == (language == "fr" ? "1 capture copiée." : "1 screenshot copied."))
        #expect(String(localized: "\(multiple) screenshots copied.", bundle: bundle)
            == (language == "fr" ? "2 captures copiées." : "2 screenshots copied."))
        #expect(String(localized: "Preview, \(single) screenshots selected.", bundle: bundle)
            == (language == "fr" ? "Aperçu, 1 capture sélectionnée." : "Preview, 1 screenshot selected."))
        #expect(String(localized: "Analysis incomplete for \(single) screenshots. All screenshots are retained.", bundle: bundle)
            == (language == "fr" ? "Analyse incomplète pour 1 capture. Toutes les captures sont conservées." : "Analysis incomplete for 1 screenshot. All screenshots are retained."))
        #expect(String(localized: "\(single) unique screenshots", bundle: bundle)
            == (language == "fr" ? "1 capture unique" : "1 unique screenshot"))
    }
}
