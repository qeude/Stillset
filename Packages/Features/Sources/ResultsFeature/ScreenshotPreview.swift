import ImageIO
import SwiftUI

struct ScreenshotPreview: View {
    let url: URL
    let maxPixelSize: Int
    var occurrenceID: UUID? = nil
    var animatesCaptureArrival = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedImage: LoadedImage?

    private struct LoadedImage {
        let occurrenceID: UUID?
        let image: CGImage
    }

    var body: some View {
        ZStack {
            if let loadedImage {
                Image(decorative: loadedImage.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .id(loadedImage.occurrenceID)
                    .transition(imageTransition)
            } else {
                ProgressView()
                    .tint(StillsetStyle.accent)
                    .transition(.identity)
            }
        }
        .animation(
            occurrenceID == nil || reduceMotion ? nil : .easeOut(duration: animatesCaptureArrival ? 0.2 : 0.14),
            value: loadedImage?.occurrenceID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
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
