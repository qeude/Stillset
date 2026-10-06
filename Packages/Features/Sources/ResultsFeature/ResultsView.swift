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

                    ProgressRail(
                        progress: model.progress,
                        isAnalyzing: model.isAnalyzing,
                        screens: model.isAnalyzing ? model.detectedScreens : [],
                        duration: model.analysisDuration,
                        screenshots: model.screenshots,
                        videoAspectRatio: videoAspectRatio
                    )
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
        .frame(height: model.isAnalyzing ? 84 : 58)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.isWorking)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.notice)
    }

    private var timeline: some View {
        let thumbnailHeight: CGFloat = 112
        let thumbnailWidth = min(160, max(48, thumbnailHeight * videoAspectRatio))

        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(model.visibleScreenshots.enumerated()), id: \.element.id) { index, screenshot in
                        let isSelected = model.selectedScreenshotIDs.contains(screenshot.id)
                        let screen = model.screenClassifications[screenshot.id]
                        ScreenshotPreview(url: screenshot.fileURL, maxPixelSize: 180)
                            .frame(width: thumbnailWidth, height: thumbnailHeight)
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
                            .overlay {
                                TimelineDragView(
                                    fileURLs: model.dragURLs(startingAt: screenshot.id),
                                    accessibilityText: "Capture \(index + 1), \(screenshot.state.representativeTimestamp.stillsetTimecode)\(isSelected ? ", sélectionnée" : "")\(screen.map { ", écran \($0.screenID), \($0.name)" } ?? "")",
                                    onClick: { modifiers in model.selectScreenshot(screenshot.id, modifiers: modifiers) },
                                    onArrow: model.moveFocus(by:)
                                )
                            }
                        .help(screen.map { "Écran \($0.screenID) · \($0.name) · \(screenshot.state.representativeTimestamp.stillsetTimecode)" } ?? screenshot.state.representativeTimestamp.stillsetTimecode)
                        .id(screenshot.id)
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .frame(height: 138)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.screenshots.count)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.selectedScreenshotIDs)
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

private struct ProgressRail: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let progress: AnalysisProgress
    var isAnalyzing = false
    var screens: [UIState] = []
    var duration: TimeInterval = 0
    var screenshots: [CapturedScreenshot] = []
    var videoAspectRatio: CGFloat = 9.0 / 19.0
    var reducesMotionInPreview = false

    private var reduceMotion: Bool {
        systemReduceMotion || reducesMotionInPreview
    }

    private var stageFraction: Double {
        progress.fraction.isFinite ? min(1, max(0, progress.fraction)) : 0
    }

    private var temporalFraction: Double {
        guard !screens.isEmpty else { return stageFraction }
        switch progress.stage {
        case .exporting, .annotating, .complete:
            return 1
        default:
            return stageFraction
        }
    }

    var body: some View {
        let fraction = temporalFraction
        let capturesByID = Dictionary(uniqueKeysWithValues: screenshots.map { ($0.id, $0) })
        let readyCount = screens.filter { capturesByID[$0.id] != nil }.count
        GeometryReader { geometry in
            let layout = ProgressRailLayout(
                screens: screens, duration: duration, width: geometry.size.width, aspectRatio: videoAspectRatio
            )
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StillsetStyle.ink.opacity(0.12))
                    .frame(width: layout.trackWidth, height: 4)
                    .offset(x: layout.inset)

                Capsule()
                    .fill(StillsetStyle.accent)
                    .frame(width: layout.trackWidth * fraction, height: 4)
                    .offset(x: layout.inset)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)

                ForEach(screens) { screen in
                    let screenshot = capturesByID[screen.id]
                    ProgressRailMarker(
                        id: screen.id,
                        screenshot: screenshot,
                        canExpand: layout.eligibleIDs.contains(screen.id),
                        targetSize: layout.targetSize,
                        reduceMotion: reduceMotion
                    )
                        .position(x: layout.centers[screen.id] ?? layout.inset, y: geometry.size.height / 2)
                        .transition(reduceMotion ? .identity : .opacity)
                        .zIndex(screenshot == nil ? 1 : 0)
                }

                if progress.stage == .decoding && fraction > 0 && fraction < 1 {
                    Circle()
                        .fill(StillsetStyle.accent)
                        .frame(width: 6, height: 6)
                        .background {
                            Circle()
                                .fill(StillsetStyle.accent.opacity(0.12))
                                .frame(width: 10, height: 10)
                        }
                        .position(x: layout.inset + layout.trackWidth * fraction, y: geometry.size.height / 2)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
                        .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: screens.count)
        }
        .frame(height: isAnalyzing ? 56 : 18)
        .transaction { if reduceMotion { $0.animation = nil } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progression")
        .accessibilityValue("\(Int(stageFraction * 100)) %, \(screens.count) écrans détectés, \(readyCount) captures prêtes")
    }
}

private struct ProgressRailLayout {
    let targetSize: CGSize
    let inset: CGFloat
    let trackWidth: CGFloat
    let centers: [UUID: CGFloat]
    let eligibleIDs: Set<UUID>

    init(screens: [UIState], duration: TimeInterval, width: CGFloat, aspectRatio: CGFloat) {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 9.0 / 19.0
        let height = min(52, 40 / ratio)
        let targetSize = CGSize(width: height * ratio, height: height)
        let inset = min(targetSize.width / 2, width / 2)
        let trackWidth = max(0, width - inset * 2)
        let positions: [(id: UUID, center: CGFloat)] = screens.map { screen in
            let fraction = duration.isFinite && duration > 0 && screen.representativeTimestamp.isFinite
                ? min(1, max(0, screen.representativeTimestamp / duration)) : 0
            return (id: screen.id, center: inset + trackWidth * CGFloat(fraction))
        }.sorted { $0.center < $1.center }
        let eligibleIDs = Set(positions.indices.filter { index in
            width >= targetSize.width
                && (index == positions.startIndex || positions[index].center - positions[index - 1].center >= targetSize.width + 4)
                && (index == positions.index(before: positions.endIndex) || positions[index + 1].center - positions[index].center >= targetSize.width + 4)
        }.map { positions[$0].id })
        self.targetSize = targetSize
        self.inset = inset
        self.trackWidth = trackWidth
        self.centers = Dictionary(uniqueKeysWithValues: positions.map { ($0.id, $0.center) })
        self.eligibleIDs = eligibleIDs
    }
}

private struct ProgressRailMarker: View {
    let id: UUID
    let screenshot: CapturedScreenshot?
    let canExpand: Bool
    let targetSize: CGSize
    let reduceMotion: Bool
    @State private var loadedOccurrenceID: UUID?

    private var isCaptured: Bool {
        screenshot != nil
    }

    private var isExpanded: Bool {
        canExpand && isCaptured && loadedOccurrenceID == id
    }

    private var markerSize: CGSize {
        isExpanded ? targetSize : CGSize(width: isCaptured ? 11 : 8, height: isCaptured ? 15 : 11)
    }

    private var cornerRadius: CGFloat {
        isExpanded ? 5 : 3
    }

    private var borderWidth: CGFloat {
        isExpanded ? 1 : isCaptured ? 1.5 : 1
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(StillsetStyle.surface)
            .frame(width: markerSize.width, height: markerSize.height)
            .overlay {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(StillsetStyle.accent.opacity(0.18))
                    .frame(width: 5, height: 7)
                    .offset(y: -1)
                    .opacity(isCaptured && !isExpanded ? 1 : 0)
            }
            .overlay { thumbnail }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StillsetStyle.accent.opacity(isCaptured ? 1 : 0.55), lineWidth: borderWidth)
            }
            .shadow(color: .black.opacity(isExpanded ? 0.1 : 0), radius: 3, y: 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: markerSize)
            .onChange(of: canExpand) { _, canExpand in
                if !canExpand { loadedOccurrenceID = nil }
            }
            .onChange(of: screenshot?.id) { _, capturedID in
                if capturedID != loadedOccurrenceID { loadedOccurrenceID = nil }
            }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if canExpand, let screenshot {
            ScreenshotPreview(
                url: screenshot.fileURL,
                maxPixelSize: 104,
                occurrenceID: id,
                showsLoadingIndicator: false,
                usesParentAnimation: true,
                onImageLoaded: { loadedID in
                    guard loadedID == id, loadedOccurrenceID != loadedID else { return }
                    loadedOccurrenceID = loadedID
                }
            )
            .frame(width: targetSize.width, height: targetSize.height)
            .opacity(isExpanded ? 1 : 0)
        }
    }
}

#Preview("Progression · clair et sombre") {
    ProgressRailPreview()
}

#Preview("Progression · mouvement réduit") {
    ProgressRailPreview(reducedMotion: true)
}

private struct ProgressRailPreview: View {
    var reducedMotion = false

    private static let sparse = [0, 0.16, 0.5, 0.78, 1].map { timestamp in
        UIState(interval: timestamp..<(timestamp + 0.04), representativeTimestamp: timestamp, stabilityScore: 1)
    }

    private static let dense = (0..<24).map { index in
        let timestamp = 0.4 + Double(index) * 0.007
        return UIState(interval: timestamp..<(timestamp + 0.004), representativeTimestamp: timestamp, stabilityScore: 1)
    }

    private static let sparseCaptures = ProgressRailPreviewImages.captures(for: sparse)
    private static let denseCaptures = ProgressRailPreviewImages.captures(for: dense)

    var body: some View {
        VStack(spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recherche · repères espacés")
                    ProgressRail(
                        progress: AnalysisProgress(stage: .decoding, fraction: 0.63, detail: "Recherche d’écrans"),
                        isAnalyzing: true,
                        screens: Self.sparse, duration: 1, reducesMotionInPreview: reducedMotion
                    )
                    Text("Captures · ordre indépendant")
                    ProgressRail(
                        progress: AnalysisProgress(stage: .exporting, fraction: 0.4, detail: "Création des captures"),
                        isAnalyzing: true,
                        screens: Self.sparse, duration: 1,
                        screenshots: [Self.sparseCaptures[3], Self.sparseCaptures[0]],
                        reducesMotionInPreview: reducedMotion
                    )
                    Text("Repérage · rail temporel complet")
                    ProgressRail(
                        progress: AnalysisProgress(stage: .annotating, fraction: 0.35, detail: "Repérage des écrans"),
                        isAnalyzing: true,
                        screens: Self.sparse, duration: 1,
                        screenshots: Self.sparseCaptures, reducesMotionInPreview: reducedMotion
                    )
                    Text("Captures · repères rapprochés")
                    ProgressRail(
                        progress: AnalysisProgress(stage: .exporting, fraction: 0.5, detail: "Création des captures"),
                        isAnalyzing: true,
                        screens: Self.dense, duration: 1,
                        screenshots: Self.denseCaptures.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element),
                        reducesMotionInPreview: reducedMotion
                    )
                    Text("Export de la sélection")
                    ProgressRail(
                        progress: AnalysisProgress(stage: .exporting, fraction: 0.35, detail: "Export de la sélection"),
                        reducesMotionInPreview: reducedMotion
                    )
                }
                .font(.caption)
                .foregroundStyle(StillsetStyle.muted)
                .padding(28)
                .background(StillsetStyle.surface)
                .environment(\.colorScheme, scheme)
            }
        }
        .frame(width: 540)
    }
}

private enum ProgressRailPreviewImages {
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StillsetProgressRailPreview-\(UUID().uuidString)", isDirectory: true)

    static func captures(for screens: [UIState]) -> [CapturedScreenshot] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return screens.enumerated().map { index, screen in
            let url = directory.appendingPathComponent("\(screen.id.uuidString).png")
            if let image = image(index: index),
               let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                _ = CGImageDestinationFinalize(destination)
            }
            return CapturedScreenshot(state: screen, fileURL: url)
        }
    }

    private static func image(index: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 104, height: 220, bitsPerComponent: 8, bytesPerRow: 104 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
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
