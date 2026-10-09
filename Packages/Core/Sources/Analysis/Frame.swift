import Foundation

public struct Frame: Sendable {
    public let timestamp: TimeInterval
    public let width: Int
    public let height: Int
    public let sourceAspectRatio: Double
    public let luma: Data
    public let previewWidth: Int?
    public let previewHeight: Int?
    public let previewRGBA: Data?

    public init(
        timestamp: TimeInterval,
        width: Int,
        height: Int,
        luma: Data,
        sourceAspectRatio: Double? = nil,
        previewWidth: Int? = nil,
        previewHeight: Int? = nil,
        previewRGBA: Data? = nil
    ) {
        self.timestamp = timestamp
        self.width = width
        self.height = height
        self.sourceAspectRatio = sourceAspectRatio ?? Double(width) / Double(max(1, height))
        self.luma = luma
        self.previewWidth = previewWidth
        self.previewHeight = previewHeight
        self.previewRGBA = previewRGBA
    }
}

public struct MotionSample: Sendable {
    public let timestamp: TimeInterval
    public let globalEnergy: Float
    public let movingAreaRatio: Float
    public let regionalEnergy: [Float]

    public init(timestamp: TimeInterval, globalEnergy: Float, movingAreaRatio: Float, regionalEnergy: [Float]) {
        self.timestamp = timestamp
        self.globalEnergy = globalEnergy
        self.movingAreaRatio = movingAreaRatio
        self.regionalEnergy = regionalEnergy
    }
}

public struct StateCandidate: Sendable {
    public let interval: Range<TimeInterval>
    public let frame: Frame
    public let stabilityScore: Float
    public let isConfirmed: Bool

    public init(interval: Range<TimeInterval>, frame: Frame, stabilityScore: Float, isConfirmed: Bool) {
        self.interval = interval
        self.frame = frame
        self.stabilityScore = stabilityScore
        self.isConfirmed = isConfirmed
    }
}
