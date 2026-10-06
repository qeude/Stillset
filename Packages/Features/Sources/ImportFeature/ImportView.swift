import SwiftUI

struct ImportView: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            VideoFanArtwork()
                .frame(maxWidth: 500)
                .frame(height: 300)

            Text("Déposez une vidéo")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(StillsetStyle.ink)

            Button("Ouvrir…", action: model.chooseVideo)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }
}

private struct VideoFanArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var replayTask: Task<Void, Never>?

    var body: some View {
        Button(action: replay) {
            ZStack {
                let cards: [(variant: Int, x: CGFloat, y: CGFloat, angle: Double)] = [
                    (0, -88, 24, -22),
                    (4, 88, 24, 22),
                    (2, -44, 6, -11),
                    (3, 44, 6, 11)
                ]

                ForEach(cards, id: \.variant) { card in
                    ArtworkScreenshot(variant: card.variant)
                        .frame(width: 116, height: 184)
                        .rotationEffect(.degrees(isExpanded ? card.angle : 0), anchor: .bottom)
                        .offset(x: isExpanded ? card.x : 0, y: isExpanded ? card.y : 0)
                        .scaleEffect(isExpanded ? 1 : 0.72)
                        .opacity(isExpanded ? 1 : 0)
                }

                ZStack {
                    ArtworkScreenshot(variant: 1)
                    videoOverlay
                        .opacity(isExpanded ? 0 : 1)
                }
                .frame(width: 120, height: 188)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(StillsetStyle.border.opacity(0.6))
                }
                .zIndex(4)
            }
            .frame(width: 420, height: 300)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rejouer l’animation de capture")
        .help("Rejouer l’animation")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else {
                isExpanded = true
                return
            }
            withAnimation(.spring(response: 1.4, dampingFraction: 0.84).delay(0.25)) {
                isExpanded = true
            }
        }
        .onDisappear { replayTask?.cancel() }
    }

    private func replay() {
        replayTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
            isExpanded = false
        }
        replayTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(320))
            } catch {
                return
            }
            withAnimation(reduceMotion ? nil : .spring(response: 1.4, dampingFraction: 0.84)) {
                isExpanded = true
            }
        }
    }

    private var videoOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.48)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(.black.opacity(0.28), in: Circle())

            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                Text("00:30")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.4), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct ArtworkScreenshot: View {
    let variant: Int

    private var accent: Color {
        switch variant {
        case 0: .mint
        case 1: StillsetStyle.accent
        case 2: .orange
        case 3: .purple
        default: .pink
        }
    }

    private var heroHeight: CGFloat {
        CGFloat([32, 43, 54, 36, 48][variant])
    }

    private var rowCount: Int {
        variant == 2 || variant == 4 ? 1 : 2
    }

    private var symbol: String {
        ["location.fill", "sparkles", "chart.bar.fill", "creditcard.fill", "photo.fill"][variant]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Capsule().fill(StillsetStyle.muted.opacity(0.45)).frame(width: 24, height: 4)
                Spacer(minLength: 0)
                Image(systemName: "ellipsis")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StillsetStyle.muted)
            }

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accent.opacity(variant.isMultiple(of: 2) ? 0.22 : 0.13))
                .overlay(alignment: variant.isMultiple(of: 2) ? .bottomLeading : .center) {
                    if variant.isMultiple(of: 2) {
                        Capsule().fill(accent.opacity(0.8)).frame(width: 28, height: 5).padding(7)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(accent)
                    }
                }
                .frame(height: heroHeight)

            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 6) {
                    Image(systemName: row == 0 ? symbol : "circle.fill")
                        .font(.system(size: row == 0 ? 9 : 5, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 22, height: 22)
                        .background(accent.opacity(row == 0 ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(StillsetStyle.ink.opacity(0.65)).frame(width: CGFloat(28 + variant * 2), height: 4)
                        Capsule().fill(StillsetStyle.muted.opacity(0.35)).frame(height: 3)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                ForEach(0..<3, id: \.self) { item in
                    Capsule()
                        .fill(item == variant % 3 ? accent.opacity(0.8) : StillsetStyle.muted.opacity(0.3))
                        .frame(width: 12, height: 4)
                    if item < 2 { Spacer(minLength: 0) }
                }
            }
        }
        .padding(9)
        .background(StillsetStyle.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(StillsetStyle.border.opacity(0.65))
        }
        .shadow(color: .black.opacity(0.09), radius: 10, y: 6)
    }
}
