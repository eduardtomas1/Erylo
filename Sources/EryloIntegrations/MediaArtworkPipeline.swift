import EryloCore
import Foundation

/// Loaders must enforce `maximumBytes` while reading, before fully materializing a larger payload.
public protocol MediaArtworkDataLoading: Sendable {
    func loadData(
        for reference: MediaArtworkReference,
        maximumBytes: Int
    ) async throws -> Data
}

public struct MediaArtworkDecodeLimits: Equatable, Sendable {
    public let maximumPixelWidth: Int
    public let maximumPixelHeight: Int
    public let maximumPixelCount: Int
    public let maximumDecodedByteCost: Int

    public init(
        maximumPixelWidth: Int = 4_096,
        maximumPixelHeight: Int = 4_096,
        maximumPixelCount: Int = 16_777_216,
        maximumDecodedByteCost: Int = 64 * 1_024 * 1_024
    ) {
        self.maximumPixelWidth = min(max(1, maximumPixelWidth), 8_192)
        self.maximumPixelHeight = min(max(1, maximumPixelHeight), 8_192)
        self.maximumPixelCount = min(max(1, maximumPixelCount), 64 * 1_024 * 1_024)
        self.maximumDecodedByteCost = min(
            max(1, maximumDecodedByteCost),
            128 * 1_024 * 1_024
        )
    }
}

public struct DecodedMediaArtwork<Artwork: Sendable>: Sendable {
    public let artwork: Artwork
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let decodedByteCost: Int

    public init(
        artwork: Artwork,
        pixelWidth: Int,
        pixelHeight: Int,
        decodedByteCost: Int
    ) {
        self.artwork = artwork
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.decodedByteCost = decodedByteCost
    }
}

/// Decoders must apply the supplied limits before allocating a full decoded image.
public protocol MediaArtworkDecoding<DecodedArtwork>: Sendable {
    associatedtype DecodedArtwork: Sendable

    func decode(
        _ data: Data,
        limits: MediaArtworkDecodeLimits
    ) async throws -> DecodedMediaArtwork<DecodedArtwork>
}

public enum MediaArtworkPipelineError: Error, Equatable, Sendable {
    case payloadTooLarge(maximumBytes: Int)
    case tooManyInFlightLoads(limit: Int)
    case invalidDecodedDimensions
    case decodedArtworkTooLarge
    case cancelled
}

/// An opt-in, coalescing, decoded-artwork memory cache with no durable playback history.
public actor BoundedMediaArtworkPipeline<Loader, Decoder>
where Loader: MediaArtworkDataLoading, Decoder: MediaArtworkDecoding {
    private struct Entry: Sendable {
        let artwork: Decoder.DecodedArtwork
        let byteCost: Int
    }

    private struct InFlight: Sendable {
        let identifier: UUID
        let generation: UInt64
        let state: MediaArtworkRequestState
        let task: Task<DecodedMediaArtwork<Decoder.DecodedArtwork>, Error>
    }

    private let loader: Loader
    private let decoder: Decoder
    private let maximumEncodedBytes: Int
    private let maximumTotalDecodedBytes: Int
    private let maximumCachedEntryBytes: Int
    private let maximumEntryCount: Int
    private let maximumInFlightLoads: Int
    private let decodeLimits: MediaArtworkDecodeLimits
    private var entries: [MediaArtworkCacheKey: Entry] = [:]
    private var leastRecentKeys: [MediaArtworkCacheKey] = []
    private var inFlight: [MediaArtworkCacheKey: InFlight] = [:]
    private var outstanding: [UUID: InFlight] = [:]
    private var totalDecodedBytes = 0
    private var purgeGeneration: UInt64 = 0

    public init(
        loader: Loader,
        decoder: Decoder,
        maximumEncodedBytes: Int = 8 * 1_024 * 1_024,
        maximumTotalDecodedBytes: Int = 32 * 1_024 * 1_024,
        maximumCachedEntryBytes: Int = 8 * 1_024 * 1_024,
        maximumEntryCount: Int = 64,
        maximumInFlightLoads: Int = 4,
        decodeLimits: MediaArtworkDecodeLimits = MediaArtworkDecodeLimits()
    ) {
        self.loader = loader
        self.decoder = decoder
        self.maximumEncodedBytes = min(max(1, maximumEncodedBytes), 16 * 1_024 * 1_024)
        self.maximumTotalDecodedBytes = min(
            max(1, maximumTotalDecodedBytes),
            128 * 1_024 * 1_024
        )
        self.maximumCachedEntryBytes = max(
            1,
            min(maximumCachedEntryBytes, self.maximumTotalDecodedBytes)
        )
        self.maximumEntryCount = min(max(1, maximumEntryCount), 256)
        self.maximumInFlightLoads = min(max(1, maximumInFlightLoads), 16)
        self.decodeLimits = decodeLimits
    }

    public func artwork(for reference: MediaArtworkReference) async throws -> Decoder.DecodedArtwork {
        let key = reference.cacheKey
        if let cached = entries[key] {
            markRecent(key)
            return cached.artwork
        }
        if let existing = inFlight[key] {
            let decoded = try await existing.task.value
            guard existing.generation == purgeGeneration, existing.state.isValid else {
                throw MediaArtworkPipelineError.cancelled
            }
            return decoded.artwork
        }
        guard outstanding.count < maximumInFlightLoads else {
            throw MediaArtworkPipelineError.tooManyInFlightLoads(
                limit: maximumInFlightLoads
            )
        }

        let identifier = UUID()
        let generation = purgeGeneration
        let requestState = MediaArtworkRequestState()
        let loader = self.loader
        let decoder = self.decoder
        let maximumEncodedBytes = self.maximumEncodedBytes
        let decodeLimits = self.decodeLimits
        let task = Task {
            let data = try await loader.loadData(
                for: reference,
                maximumBytes: maximumEncodedBytes
            )
            guard data.count <= maximumEncodedBytes else {
                throw MediaArtworkPipelineError.payloadTooLarge(
                    maximumBytes: maximumEncodedBytes
                )
            }
            let decoded = try await decoder.decode(data, limits: decodeLimits)
            try Self.validate(decoded, limits: decodeLimits)
            guard requestState.isValid, !Task.isCancelled else {
                throw MediaArtworkPipelineError.cancelled
            }
            return decoded
        }
        let operation = InFlight(
            identifier: identifier,
            generation: generation,
            state: requestState,
            task: task
        )
        inFlight[key] = operation
        outstanding[identifier] = operation

        do {
            let decoded = try await task.value
            guard inFlight[key]?.identifier == identifier,
                  generation == purgeGeneration,
                  requestState.isValid else {
                throw MediaArtworkPipelineError.cancelled
            }
            inFlight.removeValue(forKey: key)
            outstanding.removeValue(forKey: identifier)
            insert(decoded, for: key)
            return decoded.artwork
        } catch {
            if inFlight[key]?.identifier == identifier {
                inFlight.removeValue(forKey: key)
            }
            outstanding.removeValue(forKey: identifier)
            throw error
        }
    }

    public func removeAll() {
        purgeGeneration &+= 1
        for operation in outstanding.values {
            operation.state.invalidate()
            operation.task.cancel()
        }
        inFlight.removeAll(keepingCapacity: false)
        entries.removeAll(keepingCapacity: false)
        leastRecentKeys.removeAll(keepingCapacity: false)
        totalDecodedBytes = 0
    }

    public var cachedByteCount: Int {
        totalDecodedBytes
    }

    public var cachedEntryCount: Int {
        entries.count
    }

    public var inFlightLoadCount: Int {
        outstanding.count
    }

    private nonisolated static func validate(
        _ decoded: DecodedMediaArtwork<Decoder.DecodedArtwork>,
        limits: MediaArtworkDecodeLimits
    ) throws {
        guard decoded.pixelWidth > 0, decoded.pixelHeight > 0,
              decoded.pixelWidth <= limits.maximumPixelWidth,
              decoded.pixelHeight <= limits.maximumPixelHeight,
              decoded.pixelWidth <= Int.max / decoded.pixelHeight,
              decoded.pixelWidth * decoded.pixelHeight <= limits.maximumPixelCount else {
            throw MediaArtworkPipelineError.invalidDecodedDimensions
        }
        guard decoded.decodedByteCost > 0,
              decoded.decodedByteCost <= limits.maximumDecodedByteCost else {
            throw MediaArtworkPipelineError.decodedArtworkTooLarge
        }
    }

    private func insert(
        _ decoded: DecodedMediaArtwork<Decoder.DecodedArtwork>,
        for key: MediaArtworkCacheKey
    ) {
        guard decoded.decodedByteCost <= maximumCachedEntryBytes else { return }
        if let replaced = entries.removeValue(forKey: key) {
            totalDecodedBytes -= replaced.byteCost
            leastRecentKeys.removeAll { $0 == key }
        }

        while (totalDecodedBytes > maximumTotalDecodedBytes - decoded.decodedByteCost
               || entries.count >= maximumEntryCount),
              let keyToEvict = leastRecentKeys.first {
            leastRecentKeys.removeFirst()
            if let evicted = entries.removeValue(forKey: keyToEvict) {
                totalDecodedBytes -= evicted.byteCost
            }
        }

        entries[key] = Entry(
            artwork: decoded.artwork,
            byteCost: decoded.decodedByteCost
        )
        leastRecentKeys.append(key)
        totalDecodedBytes += decoded.decodedByteCost
    }

    private func markRecent(_ key: MediaArtworkCacheKey) {
        leastRecentKeys.removeAll { $0 == key }
        leastRecentKeys.append(key)
    }
}

private final class MediaArtworkRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}
