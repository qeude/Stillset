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
        .navigationTitle(model.videoURL?.lastPathComponent ?? "Stillset")
        .toolbar {
            if !model.screenshots.isEmpty || model.isAnalyzing {
                ToolbarItem(placement: .automatic) {
                    Button("Nouvelle analyse…", systemImage: "plus", action: model.chooseVideo)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Nouvelle analyse…")
                        .help("Nouvelle analyse…")
                        .disabled(model.isWorking)
                }
                .visibilityPriority(.low)
                ToolbarSpacer(.flexible)
                if !model.isAnalyzing {
                    ToolbarItem(placement: .automatic) {
                        filtersMenu
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Réanalyser", systemImage: "arrow.clockwise", action: model.reanalyze)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Réanalyser la vidéo actuelle")
                        .help("Réanalyser la vidéo actuelle")
                        .disabled(model.isWorking || model.videoURL == nil)
                }
                .visibilityPriority(.low)
                ToolbarItem(placement: .automatic) {
                    Button("Affiner avec l’IA…", systemImage: "sparkles", action: model.refineScreens)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Affiner avec l’IA…")
                        .disabled(model.isAnalyzing || model.screenshots.isEmpty || model.refinementDetail != nil)
                        .help("Affiner avec l’IA")
                }
                .visibilityPriority(.high)
                ToolbarItem(placement: .automatic) {
                    Button("Exporter…", systemImage: "square.and.arrow.up", action: model.saveSelection)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Exporter les captures sélectionnées…")
                        .help("Exporter la sélection")
                        .disabled(!model.canSaveSelection)
                }
            }
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

    private var filtersMenu: some View {
        let captures = model.showsUniqueScreens ? "Captures uniques" : "Toutes les captures"
        let organisation = model.groupsTimelineByScreen ? "Par écran" : "Chronologie"
        return Menu {
            Picker("Captures", selection: Binding(
                get: { model.showsUniqueScreens }, set: model.setUniqueScreens
            )) {
                Text("Uniques").tag(true)
                Text("Toutes").tag(false)
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Organisation", selection: Binding(
                get: { model.groupsTimelineByScreen }, set: model.setTimelineGrouping
            )) {
                Text("Chronologie").tag(false)
                Text("Par écran").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filtres", systemImage: "line.3.horizontal.decrease")
        }
        .labelStyle(.iconOnly)
        .help("Filtres")
        .accessibilityLabel("Filtres")
        .accessibilityValue("\(captures), \(organisation)")
        .disabled(model.screenClassifications.isEmpty)
    }
}
