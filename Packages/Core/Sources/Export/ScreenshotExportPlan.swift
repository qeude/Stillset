import Foundation

public enum ScreenshotExportPlan: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let sourceURL: URL
        public let screenName: String

        public init(sourceURL: URL, screenName: String) {
            self.sourceURL = sourceURL
            self.screenName = screenName
        }
    }

    public struct ScreenGroup: Sendable, Equatable {
        public let screenName: String
        public let sourceURLs: [URL]

        public init(screenName: String, sourceURLs: [URL]) {
            self.screenName = screenName
            self.sourceURLs = sourceURLs
        }
    }

    case singleFolder([Entry])
    case screenFolders([ScreenGroup])

    public var fileCount: Int {
        switch self {
        case .singleFolder(let entries): entries.count
        case .screenFolders(let groups): groups.reduce(0) { $0 + $1.sourceURLs.count }
        }
    }
}
