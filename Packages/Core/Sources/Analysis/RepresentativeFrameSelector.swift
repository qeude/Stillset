import Foundation

public struct RepresentativeFrameSelector: Sendable {
    public init() {}

    public func score(frame: Frame, motion: MotionSample, secondsFromTransition: TimeInterval) -> Float {
        let motionPenalty = min(1, motion.globalEnergy * 4 + motion.movingAreaRatio)
        let edgeSharpness = sharpness(of: frame)
        let transitionPenalty = secondsFromTransition < 0.08 ? Float(0.25) : 0
        return edgeSharpness * 0.65 + (1 - motionPenalty) * 0.35 - transitionPenalty
    }

    private func sharpness(of frame: Frame) -> Float {
        guard frame.width > 2, frame.height > 2, frame.luma.count == frame.width * frame.height else { return 0 }
        return frame.luma.withUnsafeBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            var laplacianSum: Int64 = 0
            var laplacianSquaredSum: Int64 = 0
            var count = 0

            for y in 1..<(frame.height - 1) {
                let row = y * frame.width
                for x in 1..<(frame.width - 1) {
                    let index = row + x
                    let center = Int(bytes[index])
                    let neighbors = Int(bytes[index - 1]) + Int(bytes[index + 1])
                        + Int(bytes[index - frame.width]) + Int(bytes[index + frame.width])
                    let value = Int64(neighbors - 4 * center)
                    laplacianSum += value
                    laplacianSquaredSum += value * value
                    count += 1
                }
            }

            guard count > 0 else { return 0 }
            let mean = Double(laplacianSum) / Double(count)
            let variance = max(0, Double(laplacianSquaredSum) / Double(count) - mean * mean)
            return Float(min(1, variance / 2200))
        }
    }
}
