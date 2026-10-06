import Foundation

public struct MotionAnalyzer: Sendable {
    private let gridSize = 6
    private let activeRegionThreshold: Float = 0.012
    private var persistentMotionSeconds = [TimeInterval](repeating: 0, count: 36)
    private var dynamicRegions = Set<Int>()
    private var previousTimestamp: TimeInterval?

    public init() {}

    public mutating func sample(current: Frame, previous: Frame?) -> MotionSample {
        guard let previous,
              current.width == previous.width,
              current.height == previous.height,
              current.luma.count == previous.luma.count,
              current.luma.count == current.width * current.height,
              current.width > 0,
              current.height > 0 else {
            previousTimestamp = current.timestamp
            return MotionSample(timestamp: current.timestamp, globalEnergy: 0, movingAreaRatio: 0, regionalEnergy: [])
        }

        let width = current.width
        let height = current.height
        var energy = [Float](repeating: 0, count: gridSize * gridSize)
        var pixelCounts = [Int](repeating: 0, count: energy.count)
        let delta = max(0, current.timestamp - (previousTimestamp ?? previous.timestamp))

        previous.luma.withUnsafeBytes { previousBytes in
            current.luma.withUnsafeBytes { currentBytes in
                guard let before = previousBytes.bindMemory(to: UInt8.self).baseAddress,
                      let after = currentBytes.bindMemory(to: UInt8.self).baseAddress else { return }

                for regionY in 0..<gridSize {
                    let minY = (regionY * height + gridSize - 1) / gridSize
                    let maxY = ((regionY + 1) * height + gridSize - 1) / gridSize
                    for regionX in 0..<gridSize {
                        let minX = (regionX * width + gridSize - 1) / gridSize
                        let maxX = ((regionX + 1) * width + gridSize - 1) / gridSize
                        let region = regionY * gridSize + regionX
                        pixelCounts[region] = (maxX - minX) * (maxY - minY)

                        var sum: Float = 0
                        for y in minY..<maxY {
                            let row = y * width
                            for x in minX..<maxX {
                                let index = row + x
                                let old = before[index]
                                let new = after[index]
                                sum += Float(old > new ? old - new : new - old)
                            }
                        }
                        energy[region] = sum
                    }
                }
            }
        }

        var regionalEnergy = [Float](repeating: 0, count: energy.count)
        var rawMovingCount = 0
        for index in energy.indices {
            guard pixelCounts[index] > 0 else { continue }
            let normalizedEnergy = energy[index] / Float(pixelCounts[index] * 255)
            regionalEnergy[index] = normalizedEnergy
            if normalizedEnergy >= activeRegionThreshold { rawMovingCount += 1 }
        }
        let rawMovingArea = Float(rawMovingCount) / Float(regionalEnergy.count)

        // ponytail: ignore motion isolated to persistent regions; upgrade to a spatial mask when animated content spans more than 30% of the frame.
        if rawMovingArea <= 0.30 {
            for index in persistentMotionSeconds.indices {
                if regionalEnergy[index] >= activeRegionThreshold {
                    persistentMotionSeconds[index] += delta
                    if persistentMotionSeconds[index] >= 0.75 { dynamicRegions.insert(index) }
                } else if !dynamicRegions.contains(index) {
                    persistentMotionSeconds[index] = 0
                }
            }
        }

        var effectiveMovingCount = 0
        var unmaskedDifference: Float = 0
        var unmaskedPixels = 0
        for index in energy.indices where !dynamicRegions.contains(index) {
            if regionalEnergy[index] >= activeRegionThreshold { effectiveMovingCount += 1 }
            unmaskedDifference += energy[index]
            unmaskedPixels += pixelCounts[index]
        }
        let movingAreaRatio = Float(effectiveMovingCount) / Float(regionalEnergy.count)
        let globalEnergy = unmaskedDifference / Float(max(1, unmaskedPixels) * 255)
        previousTimestamp = current.timestamp
        return MotionSample(timestamp: current.timestamp, globalEnergy: globalEnergy, movingAreaRatio: movingAreaRatio, regionalEnergy: regionalEnergy)
    }
}

public enum StabilityAnalyzer {
    public static func isMoving(_ sample: MotionSample) -> Bool {
        sample.movingAreaRatio >= 0.14 || sample.globalEnergy >= 0.10
    }
}
