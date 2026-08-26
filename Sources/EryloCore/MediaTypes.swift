import Foundation

public enum MediaSource: String, CaseIterable, Codable, Hashable, Sendable {
    case appleMusic
    case spotify

    public var bundleIdentifier: String {
        switch self {
        case .appleMusic:
            "com.apple.Music"
        case .spotify:
            "com.spotify.client"
        }
    }
}

public enum MediaPlaybackState: String, Codable, Sendable {
    case stopped
    case paused
    case playing
    case buffering
}

public struct MediaCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let play = MediaCapabilities(rawValue: 1 << 0)
    public static let pause = MediaCapabilities(rawValue: 1 << 1)
    public static let next = MediaCapabilities(rawValue: 1 << 2)
    public static let previous = MediaCapabilities(rawValue: 1 << 3)
    public static let seek = MediaCapabilities(rawValue: 1 << 4)
    public static let volume = MediaCapabilities(rawValue: 1 << 5)

    public static let transport: MediaCapabilities = [.play, .pause, .next, .previous]
}

public enum MediaValueLimits {
    public static let titleUTF8Bytes = 8 * 1_024
    public static let descriptiveTextUTF8Bytes = 4 * 1_024
    public static let identifierUTF8Bytes = 2 * 1_024
    public static let artworkURLUTF8Bytes = 8 * 1_024
    public static let cacheKeyUTF8Bytes = 2 * 1_024

    public static func isSafeText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        value.utf8.count <= maximumUTF8Bytes
            && !value.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value)
            }
    }
}

public struct MediaArtworkCacheKey: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              MediaValueLimits.isSafeText(
                  rawValue,
                  maximumUTF8Bytes: MediaValueLimits.cacheKeyUTF8Bytes
              ) else {
            throw MediaArtworkReferenceError.invalidCacheKey
        }
        self.rawValue = rawValue
    }
}

public enum MediaArtworkReferenceError: Error, Equatable, Sendable {
    case invalidCacheKey
    case invalidIdentifier
    case invalidURL
}

public struct MediaArtworkReference: Hashable, Sendable {
    public enum Location: Hashable, Sendable {
        case remoteURL(URL)
        case sourceAsset(identifier: String)
    }

    public let location: Location
    public let cacheKey: MediaArtworkCacheKey

    /// A provider URL only. Core never downloads it; a caller must opt into an injected loader.
    public init(remoteURL: URL, cacheKey: MediaArtworkCacheKey) throws {
        let absoluteString = remoteURL.absoluteString
        guard remoteURL.scheme == "https", remoteURL.host != nil,
              MediaValueLimits.isSafeText(
                  absoluteString,
                  maximumUTF8Bytes: MediaValueLimits.artworkURLUTF8Bytes
              ) else {
            throw MediaArtworkReferenceError.invalidURL
        }
        location = .remoteURL(remoteURL)
        self.cacheKey = cacheKey
    }

    /// An opaque provider-owned asset identifier, such as an Apple Music persistent track ID.
    public init(sourceAssetIdentifier: String, cacheKey: MediaArtworkCacheKey) throws {
        guard !sourceAssetIdentifier.isEmpty,
              MediaValueLimits.isSafeText(
                  sourceAssetIdentifier,
                  maximumUTF8Bytes: MediaValueLimits.identifierUTF8Bytes
              ) else {
            throw MediaArtworkReferenceError.invalidIdentifier
        }
        location = .sourceAsset(identifier: sourceAssetIdentifier)
        self.cacheKey = cacheKey
    }
}

public struct MediaUpdateStamp: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let observedAt: Date

    public init(sequence: UInt64, observedAt: Date = Date()) {
        self.sequence = sequence
        self.observedAt = observedAt
    }
}

public enum MediaCommand: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case play
        case pause
        case next
        case previous
        case seek
        case volume
    }

    case play
    case pause
    case next
    case previous
    case seek(to: TimeInterval)
    /// A normalized scalar where 0 is muted and 1 is full volume.
    case setVolume(Double)

    public var kind: Kind {
        switch self {
        case .play:
            .play
        case .pause:
            .pause
        case .next:
            .next
        case .previous:
            .previous
        case .seek:
            .seek
        case .setVolume:
            .volume
        }
    }

    public var requiredCapability: MediaCapabilities {
        switch self {
        case .play:
            .play
        case .pause:
            .pause
        case .next:
            .next
        case .previous:
            .previous
        case .seek:
            .seek
        case .setVolume:
            .volume
        }
    }

    public func normalized(for snapshot: NowPlayingSnapshot) throws -> MediaCommand {
        switch self {
        case let .seek(position):
            guard position.isFinite else {
                throw MediaError.invalidNumericValue(command: .seek)
            }
        case let .setVolume(volume):
            guard volume.isFinite else {
                throw MediaError.invalidNumericValue(command: .volume)
            }
        default:
            break
        }

        guard snapshot.capabilities.contains(requiredCapability) else {
            throw MediaError.unsupportedCommand(source: snapshot.source, command: kind)
        }

        switch self {
        case let .seek(position):
            guard let duration = snapshot.duration, duration.isFinite, duration > 0 else {
                throw MediaError.unsupportedCommand(source: snapshot.source, command: .seek)
            }
            return .seek(to: min(max(position, 0), duration))
        case let .setVolume(volume):
            return .setVolume(min(max(volume, 0), 1))
        default:
            return self
        }
    }
}

public enum MediaError: Error, Equatable, Sendable {
    case disabled(source: MediaSource)
    case sourceUnavailable(source: MediaSource)
    case permissionDenied(source: MediaSource)
    case unsupportedCommand(source: MediaSource, command: MediaCommand.Kind)
    case invalidNumericValue(command: MediaCommand.Kind)
    case invalidSnapshot(source: MediaSource)
    case malformedResponse(source: MediaSource)
    case automationFailed(source: MediaSource, exitCode: Int32?)
    case automationTimedOut(source: MediaSource)
    case responseTooLarge(source: MediaSource)
    case cancelled(source: MediaSource)
    case operationQueueFull(source: MediaSource, limit: Int)
    case commandQueueFull(source: MediaSource, limit: Int)
    case subscriberLimitReached(limit: Int)
}

public struct NowPlayingSnapshot: Equatable, Sendable {
    public let source: MediaSource
    public let stamp: MediaUpdateStamp
    public let trackIdentifier: String?
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?
    public let position: TimeInterval
    public let playbackState: MediaPlaybackState
    public let volume: Double?
    public let capabilities: MediaCapabilities
    public let artwork: MediaArtworkReference?

    public init(
        source: MediaSource,
        stamp: MediaUpdateStamp,
        trackIdentifier: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        position: TimeInterval = 0,
        playbackState: MediaPlaybackState,
        volume: Double? = nil,
        capabilities: MediaCapabilities,
        artwork: MediaArtworkReference? = nil
    ) throws {
        guard Self.isSafeOptionalText(
            trackIdentifier,
            maximumUTF8Bytes: MediaValueLimits.identifierUTF8Bytes
        ), Self.isSafeOptionalText(
            title,
            maximumUTF8Bytes: MediaValueLimits.titleUTF8Bytes
        ), Self.isSafeOptionalText(
            artist,
            maximumUTF8Bytes: MediaValueLimits.descriptiveTextUTF8Bytes
        ), Self.isSafeOptionalText(
            album,
            maximumUTF8Bytes: MediaValueLimits.descriptiveTextUTF8Bytes
        ) else {
            throw MediaError.invalidSnapshot(source: source)
        }
        if let duration, (!duration.isFinite || duration < 0) {
            throw MediaError.invalidSnapshot(source: source)
        }
        guard position.isFinite else {
            throw MediaError.invalidSnapshot(source: source)
        }
        if let volume, !volume.isFinite {
            throw MediaError.invalidSnapshot(source: source)
        }

        self.source = source
        self.stamp = stamp
        self.trackIdentifier = trackIdentifier
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = min(max(position, 0), duration ?? .greatestFiniteMagnitude)
        self.playbackState = playbackState
        self.volume = volume.map { min(max($0, 0), 1) }
        self.capabilities = capabilities
        self.artwork = artwork
    }

    /// Equality for publication dedupe. Observation sequence and wall-clock time are transport metadata.
    public func hasSameContent(as other: NowPlayingSnapshot) -> Bool {
        source == other.source
            && trackIdentifier == other.trackIdentifier
            && title == other.title
            && artist == other.artist
            && album == other.album
            && duration == other.duration
            && position == other.position
            && playbackState == other.playbackState
            && volume == other.volume
            && capabilities == other.capabilities
            && artwork == other.artwork
    }

    private static func isSafeOptionalText(_ value: String?, maximumUTF8Bytes: Int) -> Bool {
        guard let value else { return true }
        return MediaValueLimits.isSafeText(value, maximumUTF8Bytes: maximumUTF8Bytes)
    }
}

public enum MediaAdapterAvailability: String, Codable, Sendable {
    case disabled
    case inactive
    case available
    case unavailable
    case degraded
}

public struct MediaAdapterHealth: Equatable, Sendable {
    public let source: MediaSource
    public let availability: MediaAdapterAvailability
    public let lastError: MediaError?
    public let checkedAt: Date?

    public init(
        source: MediaSource,
        availability: MediaAdapterAvailability,
        lastError: MediaError? = nil,
        checkedAt: Date? = nil
    ) {
        self.source = source
        self.availability = availability
        self.lastError = lastError
        self.checkedAt = checkedAt
    }
}
