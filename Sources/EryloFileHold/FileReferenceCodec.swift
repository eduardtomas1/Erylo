import Foundation

public struct ResolvedFileReference: Sendable {
    public let url: URL

    private let startAccess: @Sendable () -> Bool
    private let stopAccess: @Sendable () -> Void

    public init(
        url: URL,
        startAccess: @escaping @Sendable () -> Bool,
        stopAccess: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func startAccessing() -> Bool {
        startAccess()
    }

    func stopAccessing() {
        stopAccess()
    }
}

public protocol FileReferenceCoding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ bookmark: Data) throws -> ResolvedFileReference
}

/// The production codec uses only Foundation security-scoped bookmark APIs.
public struct SecurityScopedFileReferenceCodec: FileReferenceCoding {
    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw FileHoldError.bookmarkCreationFailed
        }
    }

    public func resolveBookmark(_ bookmark: Data) throws -> ResolvedFileReference {
        var isStale = false
        let url: URL

        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw FileHoldError.bookmarkResolutionFailed
        }

        guard !isStale else {
            throw FileHoldError.staleBookmark
        }

        return ResolvedFileReference(
            url: url,
            startAccess: { url.startAccessingSecurityScopedResource() },
            stopAccess: { url.stopAccessingSecurityScopedResource() }
        )
    }
}
