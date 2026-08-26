import Foundation

/// Parses only `erylo://v1/{submit|cancel|status}` with a closed query allowlist.
public struct URLActivityIntegrationRoute: Sendable {
    private let handler: any ActivityIntegrationHandling

    public init(handler: any ActivityIntegrationHandling) {
        self.handler = handler
    }

    public func request(from url: URL) throws -> ActivityIntegrationRequest {
        let rawURL = url.absoluteString
        guard rawURL.utf8.count <= ActivityIntegrationAPI.maximumURLBytes else {
            throw ActivityIntegrationRouteError.inputTooLarge(
                maximumBytes: ActivityIntegrationAPI.maximumURLBytes
            )
        }
        try Self.validateRawStructure(rawURL)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "erylo",
              components.host == "v1",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil else {
            throw ActivityIntegrationRouteError.invalidRoute
        }

        let pathParts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathParts.count == 1 else { throw ActivityIntegrationRouteError.invalidRoute }
        let operation = String(pathParts[0])
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else {
                throw ActivityIntegrationRouteError.invalidValue(item.name)
            }
            guard parameters.updateValue(value, forKey: item.name) == nil else {
                throw ActivityIntegrationRouteError.duplicateParameter(item.name)
            }
        }
        return try ActivityIntegrationRequestBuilder.build(
            operationName: operation,
            parameters: parameters
        )
    }

    public func handle(_ url: URL) async -> ActivityIntegrationResponse {
        do {
            return await handler.handle(try request(from: url))
        } catch let error as ActivityIntegrationRouteError {
            return ActivityIntegrationCodec.response(for: error)
        } catch {
            return ActivityIntegrationCodec.response(for: error)
        }
    }

    private static func validateRawStructure(_ rawURL: String) throws {
        let allowedPrefixes = [
            "erylo://v1/submit",
            "erylo://v1/cancel",
            "erylo://v1/status",
        ]
        guard let prefix = allowedPrefixes.first(where: {
            rawURL == $0 || rawURL.hasPrefix($0 + "?")
        }) else {
            throw ActivityIntegrationRouteError.invalidRoute
        }
        let suffix = rawURL.dropFirst(prefix.count)
        guard !suffix.contains("#"), !suffix.contains("+") else {
            throw ActivityIntegrationRouteError.invalidRoute
        }

        let lowercased = suffix.lowercased()
        let ambiguousEscapes = ["%2f", "%3f", "%23", "%26", "%3d", "%25"]
        guard !ambiguousEscapes.contains(where: lowercased.contains) else {
            throw ActivityIntegrationRouteError.invalidRoute
        }
        guard suffix.isEmpty || suffix.first == "?" else {
            throw ActivityIntegrationRouteError.invalidRoute
        }
        if suffix.isEmpty { return }
        let rawQuery = suffix.dropFirst()
        guard !rawQuery.isEmpty else {
            throw ActivityIntegrationRouteError.invalidRoute
        }
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
                throw ActivityIntegrationRouteError.invalidRoute
            }
        }
    }
}
