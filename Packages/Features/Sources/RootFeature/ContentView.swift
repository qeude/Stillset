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
                    Button(LocalizedStringResource("Open Recordings…", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "plus", action: openVideos)
                        .labelStyle(.iconOnly)
                        .help(Text("Open a new session…", bundle: .module))
                }
                ToolbarSpacer(.flexible)
                ToolbarItem { filtersMenu }
                ToolbarItem {
                    Button(LocalizedStringResource("Refine with AI…", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "sparkles", action: session.refineScreens)
                        .labelStyle(.iconOnly)
                        .disabled(session.catalogSnapshot.inputs.isEmpty || session.refinementDetail != nil)
                        .help(Text("Refine with AI", bundle: .module))
                }
                ToolbarItem {
                    Button(LocalizedStringResource("Export…", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "square.and.arrow.up", action: session.saveSelection)
                        .labelStyle(.iconOnly)
                        .disabled(!session.canSaveSelection)
                        .help(Text("Export selection", bundle: .module))
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
            Picker(LocalizedStringResource("Screenshots", bundle: .atURL(Bundle.module.bundleURL)), selection: Binding(get: { session.showsUniqueScreens }, set: session.setUniqueScreens)) {
                Text("Unique", bundle: .module).tag(true)
                Text("All", bundle: .module).tag(false)
            }.pickerStyle(.inline)
            Divider()
            Picker(LocalizedStringResource("Organization", bundle: .atURL(Bundle.module.bundleURL)), selection: Binding(get: { session.groupsTimelineByScreen }, set: session.setTimelineGrouping)) {
                Text("Chronology", bundle: .module).tag(false)
                Text("By Screen", bundle: .module).tag(true)
            }.pickerStyle(.inline)
        } label: { Label(LocalizedStringResource("Filters", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "line.3.horizontal.decrease") }
        .labelStyle(.iconOnly)
        .help(Text("Filters", bundle: .module))
        .accessibilityValue("\(session.showsUniqueScreens ? String(localized: "Unique screenshots", bundle: .module) : String(localized: "All screenshots", bundle: .module)), \(session.groupsTimelineByScreen ? String(localized: "By Screen", bundle: .module) : String(localized: "Chronology", bundle: .module))")
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
        .accessibilityLabel(LocalizedStringResource("Session Videos", bundle: .atURL(Bundle.module.bundleURL)))
        .accessibilityValue(statusSummary)
        .help(Text("Session Videos", bundle: .module))
        .popover(isPresented: $showsStatus) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Session Videos", bundle: .module).font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(session.imports.models.enumerated()), id: \.element.id) { index, model in
                            if index > 0 { Divider() }
                            VideoImportRow(model: model, imports: session.imports)
                        }
                    }
                    if let detail = session.catalogDetail { Text(detail).font(.caption) }
                    if let detail = session.refinementDetail {
                        Text(detail).font(.caption)
                        Button(LocalizedStringResource("Stop Refinement", bundle: .atURL(Bundle.module.bundleURL)), action: session.cancelRefinement)
                    }
                    if session.isExporting {
                        Text(session.progress.detail).font(.caption)
                        ProgressView(value: session.progress.fraction)
                        Button(LocalizedStringResource("Cancel Export", bundle: .atURL(Bundle.module.bundleURL)), action: session.cancelExport)
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
        return String(localized: "Videos: \(models.count) · In progress: \(pending) · Failed: \(failures)", bundle: .module)
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
                .accessibilityLabel(LocalizedStringResource("Video \(model.importOrdinal)", bundle: .atURL(Bundle.module.bundleURL)))
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
                Button(LocalizedStringResource("Retry", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "arrow.clockwise") { imports.retry(model) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(StillsetStyle.accent)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!imports.canRetry(model))
                    .help(Text("Add a new attempt at the end of the queue", bundle: .module))
            } else if model.importState == .completed || model.importState == .review {
                Button(LocalizedStringResource("Reanalyze", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "arrow.clockwise") { imports.reanalyze(model) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!imports.canReanalyze(model))
                    .help(Text("Add a new analysis without reusing the cache", bundle: .module))
            } else if model.importState == .queued {
                Button(LocalizedStringResource("Remove", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "minus.circle") { imports.remove(model) }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fixedSize()
                    .help(Text("Remove this queued video", bundle: .module))
            } else if model.importState == .running {
                Button(LocalizedStringResource("Cancel", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "stop.circle", action: model.cancel)
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fixedSize()
                    .help(Text("Cancel analysis for this video", bundle: .module))
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
