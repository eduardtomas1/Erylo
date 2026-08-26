import Foundation

/// Parses arguments after the executable name: `v1 submit --identifier ...`.
public struct CommandLineActivityIntegrationRoute: Sendable {
    private let handler: any ActivityIntegrationHandling

    public init(handler: any ActivityIntegrationHandling) {
        self.handler = handler
    }

    public func request(from arguments: [String]) throws -> ActivityIntegrationRequest {
        guard arguments.count <= ActivityIntegrationAPI.maximumCommandLineArguments else {
            throw ActivityIntegrationRouteError.tooManyArguments(
                maximum: ActivityIntegrationAPI.maximumCommandLineArguments
            )
        }
        var remainingBytes = ActivityIntegrationAPI.maximumCommandLineBytes
        for argument in arguments {
            let argumentBytes = argument.utf8.count
            guard remainingBytes > 0, argumentBytes <= remainingBytes - 1 else {
                throw ActivityIntegrationRouteError.inputTooLarge(
                    maximumBytes: ActivityIntegrationAPI.maximumCommandLineBytes
                )
            }
            remainingBytes -= argumentBytes + 1
        }
        guard arguments.count >= 2 else { throw ActivityIntegrationRouteError.invalidRoute }
        guard arguments[0] == "v1" else {
            throw ActivityIntegrationRouteError.unsupportedVersion(arguments[0])
        }

        var parameters: [String: String] = [:]
        let remaining = arguments.dropFirst(2)
        guard remaining.count.isMultiple(of: 2) else {
            throw ActivityIntegrationRouteError.invalidRoute
        }
        var iterator = remaining.makeIterator()
        while let flag = iterator.next(), let value = iterator.next() {
            guard flag.hasPrefix("--"), flag.count > 2, !flag.dropFirst(2).contains("=") else {
                throw ActivityIntegrationRouteError.invalidRoute
            }
            let name = Self.parameterName(for: String(flag.dropFirst(2)))
            guard parameters.updateValue(value, forKey: name) == nil else {
                throw ActivityIntegrationRouteError.duplicateParameter(name)
            }
        }

        return try ActivityIntegrationRequestBuilder.build(
            operationName: arguments[1],
            parameters: parameters
        )
    }

    public func handle(_ arguments: [String]) async -> ActivityIntegrationResponse {
        do {
            return await handler.handle(try request(from: arguments))
        } catch let error as ActivityIntegrationRouteError {
            return ActivityIntegrationCodec.response(for: error)
        } catch {
            return ActivityIntegrationCodec.response(for: error)
        }
    }

    private static func parameterName(for flag: String) -> String {
        switch flag {
        case "request-id": "requestIdentifier"
        case "action-id": "actionIdentifier"
        case "action-label": "actionLabel"
        case "action-intent": "actionIntent"
        case "ttl-ms": "ttlMilliseconds"
        default: flag
        }
    }
}
