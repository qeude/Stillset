import ImageIO
import SwiftUI

struct ScreenshotPreview: View {
    let url: URL
    let maxPixelSize: Int
    var occurrenceID: UUID? = nil
    var animatesCaptureArrival = false
    var showsLoadingIndicator = true
    var previewReduceMotion = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var loadedImage: LoadedImage?

    private var reduceMotion: Bool {
        previewReduceMotion || systemReduceMotion
    }

    private struct LoadedImage {
        let occurrenceID: UUID?
        let image: CGImage
    }

    var body: some View {
        imageContent
            .animation(
                occurrenceID == nil || reduceMotion ? nil : (animatesCaptureArrival ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.24)),
                value: loadedImage?.occurrenceID
            )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            let sourceURL = url
            let pixelSize = maxPixelSize
            let imageID = occurrenceID
            let loadedImage: CGImage? = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            guard let loadedImage else { return }
            self.loadedImage = LoadedImage(occurrenceID: imageID, image: loadedImage)
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
