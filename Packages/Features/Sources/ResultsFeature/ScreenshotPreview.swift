import ImageIO
import SwiftUI

struct ScreenshotPreview: View {
    let url: URL
    let maxPixelSize: Int
    var occurrenceID: OccurrenceID? = nil
    var animatesCaptureArrival = false
    var showsLoadingIndicator = true
    var previewReduceMotion = false
    var requiresScrollVisibility = false
    var demandPriority = 0
    @Environment(\.thumbnailLoader) private var loader
    @State private var consumerID = UUID()
    @State private var scrollVisible = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var loadedImage: LoadedImage?

    private var reduceMotion: Bool {
        previewReduceMotion || systemReduceMotion
    }

    private struct LoadedImage {
        let occurrenceID: OccurrenceID?
        let image: CGImage
    }

    var body: some View {
        imageContent
            .animation(
                occurrenceID == nil || reduceMotion ? nil : (animatesCaptureArrival ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.24)),
                value: loadedImage?.occurrenceID
            )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            guard requiresScrollVisibility else { return }
            scrollVisible = visible
            updateDemand()
        }
        .onAppear { if !requiresScrollVisibility { updateDemand() } }
        .onChange(of: url) { updateDemand() }
        .onChange(of: maxPixelSize) { updateDemand() }
        .onChange(of: occurrenceID) { updateDemand() }
        .onDisappear {
            loader?.cancel(consumerID)
            if requiresScrollVisibility, loadedImage != nil { processingSignposter.emitEvent("TimelineImageRelease") }
            loadedImage = nil
            scrollVisible = false
        }
    }

    private func updateDemand() {
        guard !requiresScrollVisibility || scrollVisible else {
            loader?.cancel(consumerID)
            return
        }
        let key = ThumbnailKey(url: url, maximumPixels: maxPixelSize, captureStateID: occurrenceID?.stateID)
        loader?.demand(key, consumer: consumerID, priority: demandPriority) { image in
            guard let image else { return }
            loadedImage = LoadedImage(occurrenceID: occurrenceID, image: image)
            if requiresScrollVisibility { processingSignposter.emitEvent("TimelineImageInstall") }
        }
    }

    private var imageContent: some View {
        ZStack {
            if let loadedImage {
                Image(decorative: loadedImage.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if !showsLoadingIndicator { StillsetStyle.surface }
                    }
                    .id(loadedImage.occurrenceID)
                    .transition(imageTransition)
            } else if showsLoadingIndicator {
                ProgressView()
                    .tint(StillsetStyle.accent)
                    .transition(.identity)
            }
        }
    }

    private var imageTransition: AnyTransition {
        guard occurrenceID != nil, !reduceMotion else { return .identity }
        guard animatesCaptureArrival else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.985))
                .combined(with: .offset(y: 4)),
            removal: .opacity
        )
    }
}
