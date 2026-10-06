import SwiftUI

enum StillsetStyle {
    static let background = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let accent = Color(nsColor: NSColor(name: "StillsetAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.96, green: 0.36, blue: 0.89, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.14, blue: 0.76, alpha: 1)
    })
    static let ink = Color.primary
    static let muted = Color.secondary
}
