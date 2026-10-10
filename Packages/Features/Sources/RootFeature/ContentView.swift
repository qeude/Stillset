import SwiftUI

public struct StillsetRootView: View {
    let session: SessionModel
    let openVideos: () -> Void
    let cancelSingleVideo: () -> Void
    @State private var isDropTargeted = false

    public init(session: SessionModel, openVideos: @escaping () -> Void, cancelSingleVideo: @escaping () -> Void) {
        self.session = session
        self.openVideos = openVideos
        self.cancelSingleVideo = cancelSingleVideo
    }

    public var body: some View {
        Group {
            if session.imports.models.isEmpty {
                ImportView(chooseVideos: openVideos)
            } else {
                ResultsView(model: session, cancelSingleVideo: cancelSingleVideo)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(StillsetStyle.accent)
        .background { StillsetBackground() }
        .navigationTitle("Stillset")
        .toolbar {
            if !session.imports.models.isEmpty {
                ToolbarItem {
                    Button("Ouvrir des enregistrements…", systemImage: "plus", action: openVideos)
                        .labelStyle(.iconOnly)
                        .help("Ouvrir une nouvelle session…")
                }
                ToolbarSpacer(.flexible)
                ToolbarItem { filtersMenu }
                ToolbarItem {
                    Button("Affiner avec l’IA…", systemImage: "sparkles", action: session.refineScreens)
                        .labelStyle(.iconOnly)
                        .disabled(session.catalogSnapshot.inputs.isEmpty || session.refinementDetail != nil)
                        .help("Affiner avec l’IA")
                }
                ToolbarItem {
                    Button("Exporter…", systemImage: "square.and.arrow.up", action: session.saveSelection)
                        .labelStyle(.iconOnly)
                        .disabled(!session.canSaveSelection)
                        .help("Exporter la sélection")
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(StillsetStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.imports.enqueueDroppedVideos(urls)
        } isTargeted: { isDropTargeted = $0 }
    }

    private var filtersMenu: some View {
        Menu {
            Picker("Captures", selection: Binding(get: { session.showsUniqueScreens }, set: session.setUniqueScreens)) {
                Text("Uniques").tag(true)
                Text("Toutes").tag(false)
            }.pickerStyle(.inline)
            Divider()
            Picker("Organisation", selection: Binding(get: { session.groupsTimelineByScreen }, set: session.setTimelineGrouping)) {
                Text("Chronologie").tag(false)
                Text("Par écran").tag(true)
            }.pickerStyle(.inline)
        } label: { Label("Filtres", systemImage: "line.3.horizontal.decrease") }
        .labelStyle(.iconOnly)
        .help("Filtres")
        .accessibilityValue("\(session.showsUniqueScreens ? "Captures uniques" : "Toutes les captures"), \(session.groupsTimelineByScreen ? "Par écran" : "Chronologie")")
    }
}

struct SessionStatusButton: View {
    let session: SessionModel
    @State private var showsStatus = false
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        Button { showsStatus.toggle() } label: {
            Image(systemName: "film.stack")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28, height: 26)
                .overlay(alignment: .topTrailing) {
                    if session.imports.models.contains(where: { $0.importState.failure != nil }) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.red)
                            .offset(x: 2, y: -1)
                    }
                }
                .accessibilityHidden(true)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(.primary)
        .accessibilityLabel("Vidéos de la session")
        .accessibilityValue(statusSummary)
        .help("Vidéos de la session")
        .popover(isPresented: $showsStatus) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Vidéos de la session").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(session.imports.models.enumerated()), id: \.element.id) { index, model in
                            if index > 0 { Divider() }
                            VideoImportRow(model: model, imports: session.imports)
                        }
                    }
                    if let detail = session.catalogDetail { Text(detail).font(.caption) }
                    if let detail = session.refinementDetail {
                        Text(detail).font(.caption)
                        Button("Arrêter l’affinage", action: session.cancelRefinement)
                    }
                    if session.isExporting {
                        Text(session.progress.detail).font(.caption)
                        ProgressView(value: session.progress.fraction)
                        Button("Annuler l’export", action: session.cancelExport)
                    }
                }
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(width: 380, height: min(420, max(1, contentHeight)))
            .onKeyPress(.escape) { showsStatus = false; return .handled }
        }
    }

    private var statusSummary: String {
        let models = session.imports.models
        let pending = models.filter { $0.importState.isPending }.count
        let failures = models.filter { $0.importState.failure != nil }.count
        return "\(models.count) vidéos · \(pending) en cours" + (failures > 0 ? " · \(failures) échec(s)" : "")
    }
}

private struct VideoImportRow: View {
    let model: AppModel
    let imports: VideoImportQueue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "V\(model.importOrdinal)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel("Vidéo \(model.importOrdinal)")
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: model.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model.videoURL?.path ?? model.displayName)
                Label(model.importState.label, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(model.importState.failure != nil ? Color.red : Color.secondary)
                if let failure = model.importState.failure {
                    Text(verbatim: failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .help(failure)
                }
                if model.importState == .running || model.importState == .cancelling {
                    Text(verbatim: model.progress.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    ProgressView(value: model.progress.fraction)
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.importState.canRetry {
                Button("Réessayer", systemImage: "arrow.clockwise") { imports.retry(model) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(StillsetStyle.accent)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!imports.canRetry(model))
                    .help("Ajouter un nouvel essai à la fin de la file")
            } else if model.importState == .completed || model.importState == .review {
                Button("Réanalyser", systemImage: "arrow.clockwise") { imports.reanalyze(model) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!imports.canReanalyze(model))
                    .help("Ajouter une nouvelle analyse sans réutiliser le cache")
            } else if model.importState == .queued {
                Button("Retirer", systemImage: "minus.circle") { imports.remove(model) }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Retirer cette vidéo en attente")
            } else if model.importState == .running {
                Button("Annuler", systemImage: "stop.circle", action: model.cancel)
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Annuler l’analyse de cette vidéo")
            }
        }
        .padding(.vertical, 12)
    }

    private var statusSymbol: String {
        switch model.importState {
        case .review, .completed: "checkmark"
        case .queued: "clock"
        case .running: "hourglass"
        case .cancelling: "stop.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        }
    }
}
