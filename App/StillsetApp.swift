import SwiftUI
import StillsetFeatures

@main
struct StillsetApp: App {
    @State private var preferences: AppPreferences
    @State private var session: SessionModel

    init() {
        let preferences = AppPreferences(defaults: .standard)
        _preferences = State(initialValue: preferences)
        _session = State(initialValue: SessionModel(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup {
            StillsetRootView(session: session, openVideos: openVideos, cancelSingleVideo: cancelSingleVideo)
                .frame(minWidth: 820, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
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
