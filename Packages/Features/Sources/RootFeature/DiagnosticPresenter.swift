import AppKit
import Observation
import StillsetCore
import UniformTypeIdentifiers

@MainActor
@Observable
public final class DiagnosticPresenter {
    public private(set) var isExporting = false
    private let journal: DiagnosticJournal
    private var task: Task<Void, Never>?
    private let chooseDestination: @MainActor () -> URL?
    private let showFailure: @MainActor () -> Void

    public convenience init(journal: DiagnosticJournal) {
        self.init(journal: journal, chooseDestination: Self.saveDestination, showFailure: Self.presentFailure)
    }

    init(journal: DiagnosticJournal, chooseDestination: @escaping @MainActor () -> URL?,
         showFailure: @escaping @MainActor () -> Void) {
        self.journal = journal
        self.chooseDestination = chooseDestination
        self.showFailure = showFailure
    }

    public func export() {
        guard !isExporting else { return }
        isExporting = true
        guard let destination = chooseDestination() else {
            isExporting = false
            return
        }
        task = Task { [self] in
            defer { isExporting = false; task = nil }
            do { try await journal.export(to: destination) }
            catch { showFailure() }
        }
    }

    func waitForExport() async { await task?.value }

    private static func saveDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Stillset-diagnostic.json"
        panel.title = String(localized: "Export Diagnostic…", bundle: .module)
        panel.message = String(localized: "Save a local technical report with app and system versions, processing stages, and fixed error codes. It contains no videos, images, recognized text, filenames, paths, or personal identifiers. Nothing is sent automatically.", bundle: .module)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func presentFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not export the diagnostic.", bundle: .module)
        alert.informativeText = String(localized: "Choose another location and try again.", bundle: .module)
        alert.addButton(withTitle: String(localized: "OK", bundle: .module))
        alert.runModal()
    }
}
