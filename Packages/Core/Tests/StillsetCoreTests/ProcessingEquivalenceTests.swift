import CryptoKit
import Foundation
import ImageIO
import StillsetCore
import Testing

struct ProcessingEquivalenceTests {
    @Test func recordedWorkflowPreservesEveryProxyStateAndOriginalPNGPixel() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let expected = try JSONDecoder().decode(WorkflowEvidence.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("processing-equivalence.json")))
        let fixture = fixtures.appendingPathComponent("scroll-stops-navigation-return.mov")
        let collected = WorkflowCollector()
        let result = try await AnalysisPipeline.run(url: fixture, previewRequest: { nil }, onProgress: { _ in },
            onAnalyzedFrames: { await collected.frames($0) }, onDetectedScreens: { await collected.states($0) })
        #expect(result.duration == expected.duration)
        #expect(await collected.ids == result.states.map(\.id))
        #expect(await collected.proxies == expected.frames)
        #expect(await collected.colorFrames == 0)
        #expect(await collected.ratios == [Double(128) / 192])
        #expect(result.states.map(StateEvidence.init) == expected.states)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let streamed = WrittenEvidence()
        let files = try await ScreenshotExporter.export(states: result.states, from: fixture, to: folder,
            onScreenshot: { await streamed.append($0, $1) })
        #expect(await streamed.indices == Array(0..<5))
        #expect(await streamed.urls == files)
        let pixels = try files.map { file -> PixelEvidence in
            let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let bytes = try #require(image.dataProvider?.data)
            return PixelEvidence(height: image.height, pixels: digest(bytes as Data), width: image.width)
        }
        #expect(pixels == expected.pngs)
        let demanded = WorkflowCollector()
        let withColor = try await AnalysisPipeline.run(url: fixture, onProgress: { _ in },
            onAnalyzedFrames: { await demanded.frames($0) }, onDetectedScreens: { await demanded.states($0) })
        #expect(await demanded.ids == withColor.states.map(\.id))
        #expect(await demanded.proxies == expected.frames)
        #expect(await demanded.colorFrames > 0)
        #expect(withColor.states.map(StateEvidence.init) == expected.states)
    }
}

private struct WorkflowEvidence: Decodable {
    let duration: Double
    let frames: [ProxyEvidence]
    let pngs: [PixelEvidence]
    let states: [StateEvidence]
}
private struct ProxyEvidence: Decodable, Equatable, Sendable {
    let height: String
    let luma: String
    let time: String
    let width: String
}
private struct PixelEvidence: Decodable, Equatable {
    let height: Int
    let pixels: String
    let width: Int
}
private struct StateEvidence: Decodable, Equatable {
    let end: Double
    let score: Double
    let start: Double
    let timestamp: Double
    init(_ state: UIState) {
        end = state.interval.upperBound
        score = Double(state.stabilityScore)
        start = state.interval.lowerBound
        timestamp = state.representativeTimestamp
    }
}
private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private actor WorkflowCollector {
    private(set) var proxies: [ProxyEvidence] = []
    private(set) var ids: [UUID] = []
    private(set) var colorFrames = 0
    private(set) var ratios: Set<Double> = []
    func frames(_ frames: [Frame]) {
        proxies.append(contentsOf: frames.map { ProxyEvidence(height: String($0.height), luma: digest($0.luma),
            time: String($0.timestamp), width: String($0.width)) })
        for frame in frames {
            ratios.insert(frame.sourceAspectRatio)
            if let rgba = frame.previewRGBA {
                #expect(max(frame.previewWidth ?? 0, frame.previewHeight ?? 0) <= 1400)
                #expect(rgba.count == (frame.previewWidth ?? 0) * (frame.previewHeight ?? 0) * 4)
                colorFrames += 1
            }
        }
    }
    func states(_ states: [UIState]) { ids.append(contentsOf: states.map(\.id)) }
}
private actor WrittenEvidence {
    private(set) var indices: [Int] = []
    private(set) var urls: [URL] = []
    func append(_ index: Int, _ url: URL) { indices.append(index); urls.append(url) }
}
