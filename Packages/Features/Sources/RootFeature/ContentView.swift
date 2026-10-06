import SwiftUI

public struct StillsetRootView: View {
    var model: AppModel
    @State private var isDropTargeted = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.screenshots.isEmpty && !model.isAnalyzing {
                ImportView(model: model)
            } else {
                ResultsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(StillsetStyle.accent)
        .background {
            StillsetStyle.background
                .ignoresSafeArea()
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(StillsetStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isWorking,
                  let url = urls.first,
                  ["mov", "mp4"].contains(url.pathExtension.lowercased()) else { return false }
            model.importVideo(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert("Stillset", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
