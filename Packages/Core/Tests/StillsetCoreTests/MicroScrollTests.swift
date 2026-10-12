import CoreGraphics
import Foundation
import ImageIO
@testable import StillsetCore
import Testing

struct MicroScrollTests {
    private func write(offset: Int, blob: Bool = false) throws -> URL {
        let width = 400, height = 800
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            // Banded content: a pattern that moves with the scroll offset.
            let source = y + offset
            for x in 0..<width { pixels[y * width + x] = (source / 12 + x / 20) % 2 == 0 ? 40 : 200 }
        }
        if blob { for y in 300..<360 { for x in 100..<200 { pixels[y * width + x] = 255 } } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func aFewPixelsOfScrollAreTheSamePage() throws {
        let base = try write(offset: 0), scrolled = try write(offset: 3)
        defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: scrolled) }
        #expect(try ScreenCatalogAnalyzer.sameAfterMicroScroll(base, scrolled))
    }

    @Test func aLocalChangeIsNotTheSamePage() throws {
        let base = try write(offset: 0), changed = try write(offset: 3, blob: true)
        defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: changed) }
        #expect(try !ScreenCatalogAnalyzer.sameAfterMicroScroll(base, changed))
    }

    @Test func aLargeScrollIsNotTheSamePage() throws {
        let base = try write(offset: 0), scrolled = try write(offset: 11)
        defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: scrolled) }
        #expect(try !ScreenCatalogAnalyzer.sameAfterMicroScroll(base, scrolled))
    }
}

@Test func leadingIconIsNotPartOfTitle() {
    #expect(ScreenVisionFallback.droppingLeadingIcon("< Settings") == "Settings")
    #expect(ScreenVisionFallback.droppingLeadingIcon("A Propos") == "A Propos")
    #expect(ScreenVisionFallback.droppingLeadingIcon("Accueil") == "Accueil")
}

@Test func titleWithLeadingLetterIsLeftToTheModel() {
    func fastName(_ title: String) -> String? {
        ScreenVisionFallback.Recognition(title: title, pickerName: nil, lines: [], titleConfidence: 1, pixels: []).fastName
    }
    #expect(fastName("Q Apple Podcasts") == nil)
    #expect(fastName("Apple Podcasts") == "Apple Podcasts")
    #expect(fastName("3 Pays") == "3 Pays")
}
