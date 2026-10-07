import CoreGraphics
import Foundation
import ImageIO
import StillsetCore
import SwiftUI
import UniformTypeIdentifiers

struct ResultsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                status
                progressFooter
            }
                .padding(.horizontal, 36)
                .padding(.bottom, 16)

            if model.isAnalyzing || !model.screenshots.isEmpty {
                timeline
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    @ViewBuilder
    private var preview: some View {
        GeometryReader { geometry in
            let aspectRatio = videoAspectRatio
            let maxHeight = min(geometry.size.height * 0.88, geometry.size.width * 0.68 / aspectRatio, 620)
            let imageSize = CGSize(width: maxHeight * aspectRatio, height: maxHeight)

            ZStack {
                if !model.analysisPreviewFrames.isEmpty {
                    AnalysisFramePreview(
                        frames: model.analysisPreviewFrames,
                        startedAt: model.analysisStartedAt,
                        isAnimating: isShowingFrameAnalysis
                    )
                        .frame(width: imageSize.width, height: imageSize.height)
                        .modifier(PreviewImageChrome())
                        .transition(reduceMotion ? .identity : .opacity)
                }

                if shouldShowScreenshotPreview {
                    PhotoStackPreview(model: model, imageSize: imageSize)
                        .transition(.identity)
                } else if model.analysisPreviewFrames.isEmpty {
                    ProgressView()
                        .tint(StillsetStyle.accent)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isShowingFrameAnalysis)
        }
    }

    private var shouldShowScreenshotPreview: Bool {
        model.focusedScreenshot != nil
    }

    private var isShowingFrameAnalysis: Bool {
        model.isAnalyzing && model.progress.stage == .decoding && !model.analysisPreviewFrames.isEmpty
    }

    private var status: some View {
        let count = model.isAnalyzing ? model.detectedScreens.count : model.visibleScreenshots.count
        return VStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(count.formatted())
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                if model.showsUniqueScreens && !model.isAnalyzing {
                    Text("écran\(count == 1 ? "" : "s") unique\(count == 1 ? "" : "s")")
                } else {
                    Text("capture\(count == 1 ? "" : "s") trouvée\(count == 1 ? "" : "s")")
                }
            }
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(StillsetStyle.ink)
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: count)
            .accessibilityElement(children: .combine)

            if let focused = model.focusedScreenshot,
               let screen = model.screenClassifications[focused.id] {
                Text(screen.name)
                    .font(.headline)
                    .foregroundStyle(StillsetStyle.muted)
                    .lineLimit(2)
                    .frame(maxWidth: 500)
                    .help("Nom d’écran proposé automatiquement")
            }

            if !model.isWorking {
                HStack {
                    Picker("Captures", selection: Binding(
                        get: { model.showsUniqueScreens }, set: model.setUniqueScreens
                    )) {
                        Text("Uniques").tag(true)
                        Text("Toutes").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .help("Uniques conserve chaque état distinct ; Toutes affiche aussi les répétitions")
                    .disabled(model.screenClassifications.isEmpty)
                    Spacer()
                    Button("Affiner avec l’IA", systemImage: "sparkles", action: model.refineScreens)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(model.screenshots.isEmpty || model.refinementDetail != nil)
                        .help("Analyse facultative des cas ambigus ; peut prendre plus longtemps")
                    Button("Ouvrir une vidéo…", systemImage: "film", action: model.chooseVideo)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    if !model.selectedScreenshotIDs.isEmpty {
                        Button("Exporter…", systemImage: "square.and.arrow.up", action: model.saveSelection)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var progressFooter: some View {
        return VStack {
            if model.isWorking {
                VStack(spacing: 7) {
                    HStack(spacing: 6) {
                        if model.isAnalyzing && model.progress.stage == .decoding {
                            Text("Recherche d’écrans…")
                        } else if model.progress.stage == .annotating {
                            Text(model.progress.detail)
                        } else {
                            Text("Création des captures…")
                        }

                        Spacer()

                        if model.isAnalyzing && model.progress.stage == .exporting {
                            Text("\(model.screenshots.count) sur \(model.detectedScreens.count)")
                                .monospacedDigit()
                        } else if !model.isAnalyzing {
                            Text(model.progress.fraction.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                                .foregroundStyle(StillsetStyle.accent)
                        }

                        Button("Annuler", action: model.cancel)
                            .buttonStyle(.plain)
                            .foregroundStyle(StillsetStyle.muted)
                            .padding(.leading, 8)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StillsetStyle.muted)

                    StageProgressBar(fraction: model.progress.fraction)
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            } else if let detail = model.refinementDetail {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(detail).foregroundStyle(StillsetStyle.muted)
                    Button("Arrêter l’affinage", action: model.cancelRefinement)
                        .buttonStyle(.link)
                }
                .font(.caption)
            } else if let notice = model.notice {
                HStack(spacing: 8) {
                    Text(notice)
                        .foregroundStyle(StillsetStyle.muted)
                        .transition(reduceMotion ? .identity : .opacity)

                    if model.exportedFolderURL != nil {
                        Button("Afficher dans le Finder", action: model.showExportedFolder)
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.isWorking)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.notice)
    }

    private var timelineOccurrences: [TimelineOccurrence] {
        if model.isAnalyzing {
            return TimelineOccurrence.analyzing(screens: model.detectedScreens, screenshots: model.screenshots)
        }
        return model.visibleScreenshots.map { TimelineOccurrence(state: $0.state, capture: $0) }
    }

    private var timeline: some View {
        let thumbnailWidth = min(160, max(48, 112 * videoAspectRatio))
        let occurrences = timelineOccurrences

        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(occurrences.enumerated()), id: \.element.id) { index, occurrence in
                        let isSelected = model.selectedScreenshotIDs.contains(occurrence.id)
                        let screen = model.screenClassifications[occurrence.id]
                        TimelineOccurrenceCell(
                            occurrence: occurrence,
                            index: index,
                            width: thumbnailWidth,
                            isSelected: isSelected
                        )
                        .overlay {
                            if let screenshot = occurrence.capture {
                                TimelineDragView(
                                    fileURLs: model.dragURLs(startingAt: screenshot.id),
                                    accessibilityText: "Capture \(index + 1), \(screenshot.state.representativeTimestamp.stillsetTimecode)\(isSelected ? ", sélectionnée" : "")\(screen.map { ", écran \($0.screenID), \($0.name)" } ?? "")",
                                    onClick: { modifiers in model.selectScreenshot(screenshot.id, modifiers: modifiers) },
                                    onArrow: model.moveFocus(by:)
                                )
                            }
                        }
                        .help(screen.map { "Écran \($0.screenID) · \($0.name) · \(occurrence.state.representativeTimestamp.stillsetTimecode)" } ?? occurrence.state.representativeTimestamp.stillsetTimecode)
                        .id(occurrence.id)
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            .overlay {
                if occurrences.isEmpty {
                    TimelineEmptyState()
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 158)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.detectedScreens.count)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.screenshots.count)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.selectedScreenshotIDs)
            .onChange(of: model.detectedScreens.count) {
                if model.isAnalyzing, model.followsLatest, let last = model.detectedScreens.last {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                        proxy.scrollTo(last.id, anchor: .trailing)
                    }
                }
            }
            .onChange(of: model.screenshots.count) {
                if model.followsLatest, let last = model.screenshots.last {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                        proxy.scrollTo(last.id, anchor: .trailing)
                    }
                }
            }
            .onChange(of: model.focusNavigationID) {
                if let focusNavigationID = model.focusNavigationID {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                        proxy.scrollTo(focusNavigationID)
                    }
                }
            }
        }
    }

    private var videoAspectRatio: CGFloat {
        guard let frame = model.analysisPreviewFrames.last,
              let width = frame.previewWidth,
              let height = frame.previewHeight,
              height > 0 else { return 9.0 / 19.0 }
        return CGFloat(width) / CGFloat(height)
    }
}

private struct PhotoStackPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var model: AppModel
    let imageSize: CGSize

    var body: some View {
        let width = imageSize.width
        let height = imageSize.height
        let selectedCount = model.selectedScreenshotIDs.count
        let hasMultipleSelection = selectedCount > 1
        let sideScreenshots = FannedScreenshot.arranged(model.fanSelectedScreenshots
            .filter { $0.id != model.focusedScreenshotID }
            .prefix(8)
            .map { FannedScreenshot(
                screenshot: $0,
                selectionSlot: model.fanSlot(for: $0.id)
            ) })
        ZStack {
            ForEach(sideScreenshots) { card in
                let screenshot = card.screenshot
                let direction: CGFloat = card.isOnLeft ? -1 : 1
                let level = card.depth
                let angle = (7 + level * 5) * Double(direction)
                let spread: CGFloat = 0.22 + CGFloat(level) * 0.10

                ScreenshotPreview(url: screenshot.fileURL, maxPixelSize: 650)
                    .frame(width: width, height: height)
                    .background(StillsetStyle.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(StillsetStyle.border.opacity(0.5)) }
                    .shadow(color: .black.opacity(0.14), radius: 17, y: 8)
                    .rotationEffect(.degrees(angle), anchor: .bottom)
                    .offset(
                        x: direction * width * spread,
                        y: CGFloat(6 + level * 8)
                    )
                    .transition(reduceMotion ? .identity : .scale(scale: 0.78)
                        .combined(with: .offset(
                            x: -direction * width * spread,
                            y: -CGFloat(6 + level * 8)
                        ))
                        .combined(with: .opacity))
                    .zIndex(-Double(card.selectionSlot + 1))
            }

            if let screenshot = model.focusedScreenshot {
                ScreenshotPreview(
                    url: screenshot.fileURL,
                    maxPixelSize: 1400,
                    occurrenceID: screenshot.id,
                    animatesCaptureArrival: model.isAnalyzing && model.followsLatest
                )
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(StillsetStyle.border.opacity(0.5))
                    }
                    .shadow(color: .black.opacity(0.15), radius: 24, y: 12)
                    .overlay(alignment: .bottomTrailing) {
                        if selectedCount > 1 {
                            Text("\(selectedCount)")
                                .font(.system(size: 12, weight: .semibold))
                                .contentTransition(reduceMotion ? .identity : .numericText())
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(StillsetStyle.accent, in: Circle())
                                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                                .offset(x: 14, y: 14)
                        }
                    }
                    .zIndex(1)
            }
        }
        .frame(width: width * (hasMultipleSelection ? 3.2 : 1), height: height)
        .overlay {
            TimelineDragView(
                fileURLs: model.previewDragURLs,
                accessibilityText: "Aperçu, \(selectedCount) capture\(selectedCount == 1 ? "" : "s") sélectionnée\(selectedCount == 1 ? "" : "s")",
                onClick: nil,
                onArrow: model.moveFocus(by:)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.76, dampingFraction: 0.86), value: sideScreenshots.map(\.id))
    }
}

struct FannedScreenshot: Identifiable {
    let screenshot: CapturedScreenshot
    let selectionSlot: Int

    var position: Int = 1
    var depth: Double = 0

    var id: UUID { screenshot.id }
    var isOnLeft: Bool { selectionSlot != 0 && selectionSlot.isMultiple(of: 2) }

    static func arranged(_ cards: [Self]) -> [Self] {
        var nextPositions = [1, 2]
        let leftCount = cards.filter(\.isOnLeft).count
        let sideCounts = [cards.count - leftCount, leftCount]
        return cards.sorted { $0.selectionSlot < $1.selectionSlot }.map { card in
            let side = card.isOnLeft ? 1 : 0
            let position = nextPositions[side]
            nextPositions[side] += 2
            let depth = Double((position - 1) / 2) * min(1, 3 / Double(max(sideCounts[side] - 1, 1)))
            return Self(screenshot: card.screenshot, selectionSlot: card.selectionSlot, position: position, depth: depth)
        }
    }
}

private struct PreviewImageChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(StillsetStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(StillsetStyle.border.opacity(0.5))
            }
            .shadow(color: .black.opacity(0.15), radius: 24, y: 12)
    }
}

private struct TimelineOccurrence: Identifiable {
    let state: UIState
    let capture: CapturedScreenshot?

    var id: UUID { state.id }

    static func analyzing(screens: [UIState], screenshots: [CapturedScreenshot]) -> [Self] {
        let capturesByID = Dictionary(uniqueKeysWithValues: screenshots.map { ($0.id, $0) })
        let detectedIDs = Set(screens.map(\.id))
        return screens.map { Self(state: $0, capture: capturesByID[$0.id]) }
            + screenshots.filter { !detectedIDs.contains($0.id) }.map { Self(state: $0.state, capture: $0) }
    }
}

private struct TimelineOccurrenceCell: View {
    let occurrence: TimelineOccurrence
    let index: Int
    let width: CGFloat
    var isSelected = false
    var previewReduceMotion = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                StillsetStyle.surface
                Image(systemName: "photo")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(StillsetStyle.muted.opacity(0.65))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Capture \(index + 1), \(occurrence.state.representativeTimestamp.stillsetTimecode)")
                    .accessibilityValue("En attente")
                    .accessibilityHidden(occurrence.capture != nil)

                if let screenshot = occurrence.capture {
                    ScreenshotPreview(
                        url: screenshot.fileURL,
                        maxPixelSize: 180,
                        occurrenceID: occurrence.id,
                        showsLoadingIndicator: false,
                        previewReduceMotion: previewReduceMotion
                    )
                }
            }
            .frame(width: width, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? StillsetStyle.accent : StillsetStyle.border.opacity(0.55),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            }
            .padding(3)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(StillsetStyle.accent.opacity(0.13))
                }
            }

            Text(occurrence.state.representativeTimestamp.stillsetTimecode)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(StillsetStyle.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 3)
                .frame(height: 12)
                .accessibilityHidden(true)
        }
        .frame(width: width + 6)
    }
}

private struct TimelineEmptyState: View {
    var body: some View {
        Text("Les écrans détectés apparaîtront ici.")
            .font(.caption)
            .foregroundStyle(StillsetStyle.muted)
    }
}

private struct StageProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let fraction: Double
    var previewReduceMotion = false

    private var reduceMotion: Bool {
        previewReduceMotion || systemReduceMotion
    }

    private var stageFraction: Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(StillsetStyle.ink.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(StillsetStyle.accent)
                        .frame(width: geometry.size.width * stageFraction)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: stageFraction)
                }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progression")
        .accessibilityValue(stageFraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

#Preview("Timeline · clair et sombre") {
    OccurrenceTimelinePreview()
}

#Preview("Timeline · mouvement réduit") {
    OccurrenceTimelinePreview(previewReduceMotion: true)
}

#Preview("Timeline · paysage étroit") {
    OccurrenceTimelinePreview(aspectRatio: 16.0 / 9.0, previewWidth: 320, previewReduceMotion: true)
}

#Preview("Timeline · portrait étroit") {
    OccurrenceTimelinePreview(previewWidth: 320)
}

private struct OccurrenceTimelinePreview: View {
    var aspectRatio: CGFloat = 9.0 / 19.0
    var previewWidth: CGFloat = 540
    var previewReduceMotion = false

    private static let sparse = [0, 0.16, 0.5, 0.78, 1].map { timestamp in
        UIState(interval: timestamp..<(timestamp + 0.04), representativeTimestamp: timestamp, stabilityScore: 1)
    }
    private static let dense = (0..<24).map { index in
        let timestamp = 0.4 + Double(index) * 0.007
        return UIState(interval: timestamp..<(timestamp + 0.004), representativeTimestamp: timestamp, stabilityScore: 1)
    }
    private static let portraitSparseCaptures = TimelinePreviewImages.captures(for: sparse)
    private static let portraitDenseCaptures = TimelinePreviewImages.captures(for: dense)
    private static let landscapeSparseCaptures = TimelinePreviewImages.captures(for: sparse, aspectRatio: 16.0 / 9.0)
    private static let landscapeDenseCaptures = TimelinePreviewImages.captures(for: dense, aspectRatio: 16.0 / 9.0)

    private var sparseCaptures: [CapturedScreenshot] {
        aspectRatio > 1 ? Self.landscapeSparseCaptures : Self.portraitSparseCaptures
    }

    private var denseCaptures: [CapturedScreenshot] {
        aspectRatio > 1 ? Self.landscapeDenseCaptures : Self.portraitDenseCaptures
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recherche d’écrans…")
                    strip(screens: [], captures: [])
                    StageProgressBar(fraction: 0, previewReduceMotion: previewReduceMotion)
                    Text("Recherche · écrans détectés")
                    strip(screens: Self.sparse, captures: [])
                    StageProgressBar(fraction: 0.63, previewReduceMotion: previewReduceMotion)
                    Text("Captures · ordre indépendant")
                    strip(screens: Self.sparse, captures: [sparseCaptures[3], sparseCaptures[0]])
                    StageProgressBar(fraction: 0.4, previewReduceMotion: previewReduceMotion)
                    Text("Repérage · captures prêtes")
                    strip(screens: Self.sparse, captures: sparseCaptures)
                    StageProgressBar(fraction: 0.35, previewReduceMotion: previewReduceMotion)
                    Text("Captures · écrans rapprochés")
                    strip(
                        screens: Self.dense,
                        captures: denseCaptures.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                    )
                    StageProgressBar(fraction: 0.5, previewReduceMotion: previewReduceMotion)
                }
                .font(.caption)
                .foregroundStyle(StillsetStyle.muted)
                .padding(20)
                .background(StillsetStyle.surface)
                .environment(\.colorScheme, scheme)
            }
        }
        .frame(width: previewWidth)
    }

    private func strip(screens: [UIState], captures: [CapturedScreenshot]) -> some View {
        let occurrences = TimelineOccurrence.analyzing(screens: screens, screenshots: captures)
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(Array(occurrences.enumerated()), id: \.element.id) { index, occurrence in
                    TimelineOccurrenceCell(
                        occurrence: occurrence,
                        index: index,
                        width: min(160, max(48, 112 * aspectRatio)),
                        isSelected: occurrence.id == captures.first?.id,
                        previewReduceMotion: previewReduceMotion
                    )
                    .id(occurrence.id)
                }
            }
            .padding(3)
        }
        .overlay {
            if occurrences.isEmpty { TimelineEmptyState() }
        }
        .scrollIndicators(.hidden)
        .frame(height: 158)
    }
}

private enum TimelinePreviewImages {
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StillsetTimelinePreview-\(UUID().uuidString)", isDirectory: true)

    static func captures(for screens: [UIState], aspectRatio: CGFloat = 9.0 / 19.0) -> [CapturedScreenshot] {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("Impossible de créer les images de prévisualisation : \(error)")
        }
        return screens.enumerated().map { index, screen in
            let url = directory.appendingPathComponent("\(screen.id.uuidString)-\(aspectRatio).png")
            guard let image = image(index: index, aspectRatio: aspectRatio),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                preconditionFailure("Impossible de préparer une image de prévisualisation")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                preconditionFailure("Impossible d’écrire une image de prévisualisation")
            }
            return CapturedScreenshot(state: screen, fileURL: url)
        }
    }

    private static func image(index: Int, aspectRatio: CGFloat) -> CGImage? {
        let width = max(1, Int(220 * aspectRatio))
        guard let context = CGContext(
            data: nil, width: width, height: 220, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: CGFloat(width) / 104, y: 1)
        let hue = CGFloat(index % 5) / 5
        context.setFillColor(CGColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 104, height: 220))
        context.setFillColor(CGColor(red: 0.16 + hue * 0.3, green: 0.35, blue: 0.7 - hue * 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 182, width: 104, height: 38))
        context.fill(CGRect(x: 8, y: 18, width: 88, height: 12))
        for row in 0..<4 {
            let y = CGFloat(142 - row * 34)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 8, y: y, width: 88, height: 26))
            context.setFillColor(CGColor(red: 0.35, green: 0.57 + hue * 0.15, blue: 0.78, alpha: 1))
            context.fill(CGRect(x: 13, y: y + 5, width: 16, height: 16))
            context.setFillColor(CGColor(gray: 0.55, alpha: 1))
            context.fill(CGRect(x: 35, y: y + 15, width: CGFloat(40 - (index + row) % 3 * 7), height: 3))
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(CGRect(x: 35, y: y + 8, width: 48, height: 3))
        }
        return context.makeImage()
    }
}

private struct AnalysisFramePreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let frames: [Frame]
    let startedAt: Date
    let isAnimating: Bool

    @State private var lastDisplayedFrameTimestamp: TimeInterval?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: reduceMotion || !isAnimating || frames.count < 2)) { context in
            if !frames.isEmpty {
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                let index = Int(elapsed / 0.14) % frames.count
                let fallbackFrame = frames[reduceMotion ? 0 : index]
                let frame = isAnimating && !reduceMotion
                    ? frames[index]
                    : frames.first { $0.timestamp == lastDisplayedFrameTimestamp } ?? fallbackFrame
                if let image = makeImage(frame) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .transition(reduceMotion ? .identity : .opacity)
                        .id(frame.timestamp)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: frame.timestamp)
                        .onAppear { lastDisplayedFrameTimestamp = frame.timestamp }
                        .onChange(of: frame.timestamp) {
                            lastDisplayedFrameTimestamp = frame.timestamp
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func makeImage(_ frame: Frame) -> CGImage? {
        guard let pixels = frame.previewRGBA,
              let width = frame.previewWidth,
              let height = frame.previewHeight,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

extension TimeInterval {
    var stillsetTimecode: String {
        let milliseconds = max(0, Int((self * 1000).rounded()))
        return String(
            format: "%02d:%02d.%03d",
            milliseconds / 60_000,
            (milliseconds / 1_000) % 60,
            milliseconds % 1_000
        )
    }
}
