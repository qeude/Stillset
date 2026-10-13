import SwiftUI
import UniformTypeIdentifiers

public struct StillsetRootView: View {
    let session: SessionModel
    let openVideos: () -> Void
    let replaceVideos: ([URL]) -> Void
    let cancelSingleVideo: () -> Void
    @State private var isDropTargeted = false
    @State private var hoveredZone: DropZone?
    @State private var dropToken = DropToken()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum DropZone { case add, replace }

    public init(session: SessionModel, openVideos: @escaping () -> Void, replaceVideos: @escaping ([URL]) -> Void,
                cancelSingleVideo: @escaping () -> Void) {
        self.session = session
        self.openVideos = openVideos
        self.replaceVideos = replaceVideos
        self.cancelSingleVideo = cancelSingleVideo
    }

    public var body: some View {
        Group {
            if session.imports.models.isEmpty {
                ImportView(chooseVideos: openVideos).transition(.opacity)
            } else {
                ResultsView(model: session, cancelSingleVideo: cancelSingleVideo).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: session.imports.models.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(StillsetStyle.accent)
        .background { StillsetBackground() }
        .navigationTitle("Stillset")
        .toolbar {
            if !session.imports.models.isEmpty {
                ToolbarItem { openControl }
                ToolbarSpacer(.flexible)
                ToolbarItem { filtersMenu }
                ToolbarItem {
                    Button(LocalizedStringResource("Export…", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "square.and.arrow.up", action: session.saveSelection)
                        .labelStyle(.iconOnly)
                        .disabled(!session.canSaveSelection)
                        .help(Text("Export selection", bundle: .module))
                }
            }
        }
        .overlay {
            if showsDropOverlay {
                HStack(spacing: 16) { dropZones }
                    .padding(10)
                    .background { StillsetBackground() }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: showsDropOverlay)
        .onDrop(of: [.fileURL], delegate: VideoDropDelegate(token: dropToken, verifies: true, isTargeted: $isDropTargeted) {
            drop($0, session.preferences.existingSessionAction == .replace ? .replace : .add)
        })
    }

    private var showsDropOverlay: Bool { isDropTargeted || hoveredZone != nil }

    @ViewBuilder private var dropZones: some View {
        let add = dropZone(.add, Text("Add to this session", bundle: .module), systemImage: "plus.rectangle.on.rectangle")
        let new = dropZone(.replace, Text("Start a new session", bundle: .module), systemImage: "rectangle.badge.plus")
        if session.imports.models.isEmpty {
            dropZone(.add, Text("Drop your videos", bundle: .module), systemImage: "square.and.arrow.down")
        } else {
            switch session.preferences.existingSessionAction {
            case .ask: add; new
            case .add: add
            case .replace: new
            }
        }
    }

    @ViewBuilder private var openControl: some View {
        let add = LocalizedStringResource("Add Videos to Session…", bundle: .atURL(Bundle.module.bundleURL))
        let new = LocalizedStringResource("New Session…", bundle: .atURL(Bundle.module.bundleURL))
        switch session.preferences.existingSessionAction {
        case .ask:
            Menu {
                Button(add, action: session.imports.chooseVideos)
                Button(new, action: openVideos)
            } label: {
                Label(LocalizedStringResource("Open Recordings…", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "plus")
            }
            .labelStyle(.iconOnly)
            .help(Text("Open Recordings…", bundle: .module))
        case .add:
            Button(add, systemImage: "plus", action: session.imports.chooseVideos)
                .labelStyle(.iconOnly)
                .help(Text("Add Videos to Session…", bundle: .module))
        case .replace:
            Button(new, systemImage: "plus", action: openVideos)
                .labelStyle(.iconOnly)
                .help(Text("New Session…", bundle: .module))
        }
    }

    private func drop(_ providers: [NSItemProvider], _ zone: DropZone) -> Bool {
        Task { _ = drop(await fileURLs(of: providers), zone) }
        return !providers.isEmpty
    }

    private func drop(_ urls: [URL], _ zone: DropZone) -> Bool {
        switch zone {
        case .add:
            return session.imports.enqueueDroppedVideos(urls)
        case .replace:
            let videos = urls.filter(VideoImportQueue.supportsVideo)
            guard !videos.isEmpty else { return false }
            replaceVideos(videos)
            return true
        }
    }

    private func dropZone(_ zone: DropZone, _ title: Text, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34))
            title.font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(StillsetStyle.accent)
        .background(StillsetStyle.accent.opacity(hoveredZone == zone ? 0.12 : 0.04), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(StillsetStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: hoveredZone)
        .contentShape(.rect)
        .onDrop(of: [.fileURL], delegate: VideoDropDelegate(token: dropToken, verifies: false, isTargeted: Binding(
            get: { hoveredZone == zone },
            set: { if $0 { hoveredZone = zone } else if hoveredZone == zone { hoveredZone = nil } }
        )) { drop($0, zone) })
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
                Text("By screen", bundle: .module).tag(true)
            }.pickerStyle(.inline)
        } label: { Label(LocalizedStringResource("Filters", bundle: .atURL(Bundle.module.bundleURL)), systemImage: "line.3.horizontal.decrease") }
        .labelStyle(.iconOnly)
        .help(Text("Filters", bundle: .module))
        .accessibilityValue("\(session.showsUniqueScreens ? String(localized: "Unique screenshots", bundle: .module) : String(localized: "All screenshots", bundle: .module)), \(session.groupsTimelineByScreen ? String(localized: "By screen", bundle: .module) : String(localized: "Chronology", bundle: .module))")
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
        .accessibilityLabel(LocalizedStringResource("Session videos", bundle: .atURL(Bundle.module.bundleURL)))
        .accessibilityValue(statusSummary)
        .help(Text("Session videos", bundle: .module))
        .popover(isPresented: $showsStatus) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Session videos", bundle: .module).font(.headline)
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

/// Invalidates in-flight drag verifications once the drag exits or drops.
private final class DropToken { var value = 0 }

@MainActor private func fileURLs(of providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers {
        let url = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
        if let url { urls.append(url) }
    }
    return urls
}

/// Reports a drag as targeted only when it carries a supported video, so images (e.g. exported captures) show no drop UI.
private struct VideoDropDelegate: DropDelegate {
    let token: DropToken
    let verifies: Bool
    let isTargeted: Binding<Bool>
    let perform: ([NSItemProvider]) -> Bool

    func dropEntered(info: DropInfo) {
        token.value += 1
        guard verifies else { return isTargeted.wrappedValue = true }
        let generation = token.value
        let providers = info.itemProviders(for: [.fileURL])
        Task {
            let urls = await fileURLs(of: providers)
            if token.value == generation, urls.contains(where: VideoImportQueue.supportsVideo) { isTargeted.wrappedValue = true }
        }
    }

    func dropExited(info: DropInfo) {
        token.value += 1
        isTargeted.wrappedValue = false
    }

    func performDrop(info: DropInfo) -> Bool {
        token.value += 1
        isTargeted.wrappedValue = false
        return perform(info.itemProviders(for: [.fileURL]))
    }
}
