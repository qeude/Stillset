import Foundation
@testable import StillsetCore
import Testing

struct LocalPickerEvidenceTests {
    @Test(arguments: [false, true])
    func scrollIgnoresGlyphChangesButPreservesControlsAndHeader(controlsOnLeft: Bool) {
        let background = [UInt8](repeating: 245, count: 128 * 24 * 4)
        let originalPixels = [UInt8](repeating: 245, count: 128 * 256 * 4)
        var originalLines = ["Kilométrage", "15 000 km", "50 000 km", "100 000 km"].enumerated().map { index, text in
            ScreenVisionFallback.TextLine(text: text,
                box: CGRect(x: 0.1, y: 0.75 - Double(index) * 0.12, width: 0.2, height: 0.02),
                confidence: 1, rowPixels: background)
        }
        for index in 1..<originalLines.count {
            paint(&originalLines[index].rowPixels, columns: 16..<24, rows: 8..<16)
        }
        let original = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: originalLines, titleConfidence: 1, pixels: originalPixels)
        let movedLines = originalLines.enumerated().map { index, line in
            var pixels = background
            if index > 0 { paint(&pixels, columns: 24..<32, rows: 8..<16) }
            return ScreenVisionFallback.TextLine(text: line.text,
                box: line.box.offsetBy(dx: 0, dy: index == 0 ? 0 : 0.02),
                confidence: 1, rowPixels: pixels)
        }
        var movedPixels = originalPixels
        paint(&movedPixels, columns: 32..<64, rows: 70..<78)
        let scrolled = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: movedLines, titleConfidence: 1, pixels: movedPixels)
        #expect(original.sameState(as: scrolled) == true,
            "Identical labels and controls can match despite shifted glyph pixels.")

        var selectedLines = movedLines
        paint(&selectedLines[1].rowPixels, columns: controlsOnLeft ? 0..<4 : 112..<120, rows: 8..<16)
        let selected = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: selectedLines, titleConfidence: 1, pixels: movedPixels)
        #expect(original.sameState(as: selected) != true, "Changed selection controls must stay separate.")

        var headerLines = movedLines
        paint(&headerLines[0].rowPixels, columns: 48..<80, rows: 8..<16)
        let changedHeader = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: headerLines, titleConfidence: 1, pixels: movedPixels)
        #expect(original.sameState(as: changedHeader) != true, "The fixed header still needs visual agreement.")

        var changedLabels = movedLines
        changedLabels[2] = ScreenVisionFallback.TextLine(text: "60 000 km", box: movedLines[2].box,
            confidence: 1, rowPixels: movedLines[2].rowPixels)
        let changedValue = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: changedLabels, titleConfidence: 1, pixels: movedPixels)
        #expect(original.sameState(as: changedValue) != true, "Changed option values must stay separate.")
    }

    private func paint(_ pixels: inout [UInt8], columns: Range<Int>, rows: Range<Int>) {
        for y in rows {
            for x in columns {
                for channel in 0..<3 { pixels[(y * 128 + x) * 4 + channel] = 20 }
            }
        }
    }
}
