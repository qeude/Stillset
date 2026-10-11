import SwiftUI
import StillsetFeatures
import StillsetCore

@main
struct StillsetApp: App {
    @State private var preferences: AppPreferences
    @State private var session: SessionModel
    private let diagnostics: DiagnosticJournal
    @State private var diagnosticPresenter: DiagnosticPresenter

    init() {
        let preferences = AppPreferences(defaults: .standard)
        let support = URL.applicationSupportDirectory.appendingPathComponent("com.qeude.stillset", isDirectory: true)
        let diagnostics = DiagnosticJournal(storeURL: support.appendingPathComponent("diagnostics.json"),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        self.diagnostics = diagnostics
        _diagnosticPresenter = State(initialValue: DiagnosticPresenter(journal: diagnostics))
        _preferences = State(initialValue: preferences)
        _session = State(initialValue: SessionModel(preferences: preferences, diagnostics: diagnostics))
    }

    var body: some Scene {
        WindowGroup {
            StillsetRootView(session: session, openVideos: openVideos, cancelSingleVideo: cancelSingleVideo)
                .frame(minWidth: 820, minHeight: 620)
                .task { await diagnostics.prepare() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .help) {
                Button("Export Diagnostic…", action: diagnosticPresenter.export)
                    .disabled(diagnosticPresenter.isExporting)
                Button("Clear Analysis Cache") { Task { try? await RecentAnalysisCache.shared.removeAll() } }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Recordings…", action: openVideos)
                    .keyboardShortcut("o", modifiers: .command)
                Button("Add Videos to Session…", action: session.imports.chooseVideos)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy Screenshots", action: session.copySelection)
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(session.canCopySelection == false)
            }
            CommandGroup(after: .pasteboard) {
                Button("Select All", action: session.selectAll)
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(session.hasScreenshots == false)
                Button("Save Screenshots…", action: session.saveSelection)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(session.canSaveSelection == false)
            }
        }

        Settings {
            SettingsView(preferences: preferences)
        }
    }

    private func openVideos() {
        guard let urls = VideoImportQueue.chooseVideoURLs(), !urls.isEmpty else { return }
        session = session.replacingVideos(urls)
    }

    private func cancelSingleVideo() {
        session = session.replacingVideos([])
    }
}
