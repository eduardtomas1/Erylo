import CoreGraphics
import Foundation

/// A session-scoped representation of `CGDirectDisplayID` for domain code.
///
/// This value is suitable for addressing a live display only. It must never be
/// persisted because Core Graphics may assign a different value after restart or
/// display reconfiguration.
public struct DisplayIdentity: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// The stable Core Graphics UUID used to reconnect a saved display preference to
/// its current session-scoped `DisplayIdentity`.
public struct DisplayUUID: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public init(_ uuid: UUID) {
        rawValue = uuid.uuidString.lowercased()
    }

    public static func < (lhs: DisplayUUID, rhs: DisplayUUID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let decoded = DisplayUUID(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Display UUID is malformed."
            )
        }
        self = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
    public let uuid: DisplayUUID
    public let localizedName: String
    public let geometry: DisplayGeometry
    public let isMain: Bool
    public let isMirrored: Bool

    public init(
        identity: DisplayIdentity,
        uuid: DisplayUUID,
        localizedName: String = "Display",
        geometry: DisplayGeometry,
        isMain: Bool = false,
        isMirrored: Bool = false
    ) {
        self.identity = identity
        self.uuid = uuid
        self.localizedName = localizedName
        self.geometry = geometry
        self.isMain = isMain
        self.isMirrored = isMirrored
    }
}
