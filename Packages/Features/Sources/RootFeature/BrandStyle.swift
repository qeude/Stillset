import SwiftUI

enum StillsetStyle {
    static let background = Color(nsColor: NSColor(name: "StillsetBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.065, green: 0.055, blue: 0.072, alpha: 1)
            : .underPageBackgroundColor
    })
    static let surface = Color(nsColor: NSColor(name: "StillsetSurface") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.095, green: 0.075, blue: 0.105, alpha: 1)
            : .windowBackgroundColor
    })
    static let border = Color(nsColor: .separatorColor)
    static let accent = Color(nsColor: NSColor(name: "StillsetAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.96, green: 0.36, blue: 0.89, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.14, blue: 0.76, alpha: 1)
    })
    static let ink = Color.primary
    static let muted = Color.secondary
}

struct StillsetBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        StillsetStyle.background
            .overlay {
                if contrast != .increased {
                    GeometryReader { geometry in
                        let height = min(geometry.size.height * 0.55, 380)
                        ZStack(alignment: .topLeading) {
                            Ellipse()
                                .fill(StillsetStyle.accent.opacity(colorScheme == .dark ? 0.17 : 0.10))
                                .frame(width: geometry.size.width * 0.78, height: height)
                                .blur(radius: 70)
                                .offset(x: -geometry.size.width * 0.08, y: -height * 0.64)
                            Ellipse()
                                .fill(StillsetStyle.accent.opacity(colorScheme == .dark ? 0.11 : 0.065))
                                .frame(width: geometry.size.width * 0.48, height: height * 0.65)
                                .blur(radius: 55)
                                .rotationEffect(.degrees(-12))
                                .offset(x: geometry.size.width * 0.48, y: -height * 0.36)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .clipped()
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview("Accueil · clair") {
    ImportView(chooseVideos: {})
        .frame(width: 820, height: 620)
        .tint(StillsetStyle.accent)
        .background { StillsetBackground() }
        .preferredColorScheme(.light)
}
