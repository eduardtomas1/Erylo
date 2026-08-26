import CoreGraphics
import Foundation

/// A stable, dependency-free representation of `CGDirectDisplayID` for domain code.
public struct DisplayIdentity: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct TopEdgeOcclusion: Equatable, Sendable {
    public let frame: CGRect

    public init(frame: CGRect) {
        self.frame = frame
    }
}

public struct DisplayGeometry: Equatable, Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let backingScaleFactor: CGFloat
    public let topEdgeOcclusion: TopEdgeOcclusion?

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        backingScaleFactor: CGFloat,
        topEdgeOcclusion: TopEdgeOcclusion?
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScaleFactor = backingScaleFactor
        self.topEdgeOcclusion = topEdgeOcclusion
    }
}

public struct DisplaySnapshot: Equatable, Sendable {
    public let identity: DisplayIdentity
    public let geometry: DisplayGeometry
    public let isMain: Bool
    public let isMirrored: Bool

    public init(
        identity: DisplayIdentity,
        geometry: DisplayGeometry,
        isMain: Bool = false,
        isMirrored: Bool = false
    ) {
        self.identity = identity
        self.geometry = geometry
        self.isMain = isMain
        self.isMirrored = isMirrored
    }
}
