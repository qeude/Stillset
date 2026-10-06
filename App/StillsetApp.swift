import SwiftUI
import StillsetFeatures

@main
struct StillsetApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            StillsetRootView(model: model)
                .frame(minWidth: 820, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ouvrir un enregistrement…", action: model.chooseVideo)
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copier les captures", action: model.copySelection)
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(!model.canCopySelection)
            }
            CommandGroup(after: .pasteboard) {
                Button("Tout sélectionner", action: model.selectAll)
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(!model.hasScreenshots)
                Button("Enregistrer les captures…", action: model.saveSelection)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSaveSelection)
            }
        }
    }
}
