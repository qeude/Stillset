import Foundation
import Testing
@testable import StillsetCore

struct CoreLocalizationTests {
    @Test(arguments: ["en", "fr"])
    func recognitionAndDecoderMessages(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(String(localized: "Screenshot to Review", bundle: bundle)
            == (language == "fr" ? "Capture à examiner" : "Screenshot to Review"))
        #expect(String(localized: "This recording has no video track.", bundle: bundle)
            == (language == "fr" ? "Cet enregistrement ne contient aucune piste vidéo." : "This recording has no video track."))
        #expect(String(localized: "Choose \("Year")", bundle: bundle)
            == (language == "fr" ? "Choix de Year" : "Choose Year"))
    }
}
