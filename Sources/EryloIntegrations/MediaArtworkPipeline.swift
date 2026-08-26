import EryloCore
import Foundation

/// Loaders are injected so media adapters never perform hidden network or filesystem work.
public protocol MediaArtworkDataLoading: Sendable {
    func loadData(for reference: MediaArtworkReference) async throws -> Data
}

/// Conformers decode away from the main actor and return an explicitly Sendable representation.
public protocol MediaArtworkDecoding<DecodedArtwork>: Sendable {
    associatedtype DecodedArtwork: Sendable

    func decode(_ data: Data) async throws -> DecodedArtwork
}

public enum MediaArtworkPipelineError: Error, Equatable, Sendable {
    case payloadTooLarge(maximumBytes: Int)
}

/// An opt-in, memory-only artwork path. It retains no durable playback history.
public actor BoundedMediaArtworkPipeline<Loader, Decoder>
where Loader: MediaArtworkDataLoading, Decoder: MediaArtworkDecoding {
    private struct Entry: Sendable {
        let data: Data
        let byteCount: Int
    }

    private let loader: Loader
    private let decoder: Decoder
    private let maximumTotalBytes: Int
    private let maximumEntryBytes: Int
    private let maximumDecodeBytes: Int
    private var entries: [MediaArtworkCacheKey: Entry] = [:]
    private var leastRecentKeys: [MediaArtworkCacheKey] = []
    private var totalBytes = 0

    public init(
        loader: Loader,
        decoder: Decoder,
        maximumTotalBytes: Int = 16 * 1_024 * 1_024,
        maximumEntryBytes: Int = 4 * 1_024 * 1_024,
        maximumDecodeBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.loader = loader
        self.decoder = decoder
        self.maximumTotalBytes = max(0, maximumTotalBytes)
        self.maximumEntryBytes = max(0, min(maximumEntryBytes, maximumTotalBytes))
        self.maximumDecodeBytes = max(0, maximumDecodeBytes)
    }

    public func artwork(for reference: MediaArtworkReference) async throws -> Decoder.DecodedArtwork {
        let key = reference.cacheKey
        if let cached = entries[key] {
            markRecent(key)
            return try await decoder.decode(cached.data)
        }

        let data = try await loader.loadData(for: reference)
        guard data.count <= maximumDecodeBytes else {
            throw MediaArtworkPipelineError.payloadTooLarge(maximumBytes: maximumDecodeBytes)
        }
        if data.count <= maximumEntryBytes {
            insert(data, for: key)
        }
        return try await decoder.decode(data)
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: false)
        leastRecentKeys.removeAll(keepingCapacity: false)
        totalBytes = 0
    }

    public var cachedByteCount: Int {
        totalBytes
    }

    public var cachedEntryCount: Int {
        entries.count
    }

    private func insert(_ data: Data, for key: MediaArtworkCacheKey) {
        if let replaced = entries.removeValue(forKey: key) {
            totalBytes -= replaced.byteCount
            leastRecentKeys.removeAll { $0 == key }
        }

        while totalBytes + data.count > maximumTotalBytes, let keyToEvict = leastRecentKeys.first {
            leastRecentKeys.removeFirst()
            if let evicted = entries.removeValue(forKey: keyToEvict) {
                totalBytes -= evicted.byteCount
            }
        }

        guard data.count <= maximumTotalBytes else { return }
        entries[key] = Entry(data: data, byteCount: data.count)
        leastRecentKeys.append(key)
        totalBytes += data.count
    }

    private func markRecent(_ key: MediaArtworkCacheKey) {
        leastRecentKeys.removeAll { $0 == key }
        leastRecentKeys.append(key)
    }
}
