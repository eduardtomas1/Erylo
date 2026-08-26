import EryloActivity
import EryloLocalIntegrations
import Foundation

extension IntegrationHarness {
    func verifyStrictSchemaAndSharedBroker() async {
        let broker = ActivityBroker()
        let controller = ActivityIntegrationController(broker: broker)
        do {
            let request = try ActivityIntegrationCodec.decodeRequest(
                Data(
                    #"{"version":1,"requestIdentifier":"schema-1","operation":"submit","activity":{"identifier":"build","source":"external","kind":"generic","priority":60,"title":"Build complete","detail":"Ready","progress":1,"ttlMilliseconds":1000}}"#.utf8
                )
            )
            let submitted = await controller.handle(request)
            check(submitted.isSuccess, "strict schema accepts one valid submit")
            check(submitted.requestIdentifier == "schema-1", "request identifier round trips")
            check(submitted.result?.snapshot.current?.identifier == "build", "submit reaches the injected broker")
            check(
                await broker.snapshot().current?.activity.identity.identifier.rawValue == "build",
                "shared broker observes integration mutations"
            )

            _ = try await broker.submit(
                ActivityRequest(
                    identifier: "provider-item",
                    source: "timer",
                    kind: "timer",
                    priority: 70,
                    title: "Provider"
                )
            )
            let status = await controller.handle(try ActivityIntegrationRequest(operation: .status))
            check(status.result?.snapshot.current?.identifier == "provider-item", "integration status observes provider mutations")

            let cancelled = await controller.handle(
                try ActivityIntegrationRequest(
                    operation: .cancel,
                    identity: ActivityIntegrationIdentity(source: "external", identifier: "build")
                )
            )
            check(cancelled.result?.cancelled == true, "declarative cancellation removes one identity")
            let absent = await controller.handle(
                try ActivityIntegrationRequest(
                    operation: .cancel,
                    identity: ActivityIntegrationIdentity(source: "external", identifier: "build")
                )
            )
            check(absent.result?.cancelled == false, "repeated cancellation is deterministic")
        } catch {
            recordUnexpected(error, context: "valid strict schema")
        }

        expectSchemaError(
            .unknownField("command"),
            json: #"{"version":1,"operation":"status","command":"whoami"}"#,
            name: "unknown executable field is rejected"
        )
        expectSchemaError(
            .unknownField("url"),
            json: #"{"version":1,"operation":"status","url":"file:///tmp/x"}"#,
            name: "unknown URL field is rejected"
        )
        expectSchemaError(
            .duplicateField("operation"),
            json: #"{"version":1,"operation":"status","operation":"cancel"}"#,
            name: "duplicate top-level key is rejected before Codable"
        )
        expectSchemaError(
            .duplicateField("title"),
            json: #"{"version":1,"operation":"submit","activity":{"identifier":"x","source":"external","kind":"generic","priority":1,"title":"one","title":"two"}}"#,
            name: "duplicate nested key is rejected before Codable"
        )
        expectSchemaError(
            .duplicateField("operation"),
            json: #"{"version":1,"operation":"status","\u006fperation":"cancel"}"#,
            name: "escaped duplicate key resolves canonically"
        )
        expectSchemaError(
            .unsupportedVersion(2),
            json: #"{"version":2,"operation":"status"}"#,
            name: "unsupported body version is rejected"
        )
        expectSchemaError(
            .invalidShape("status forbids activity and identity"),
            json: #"{"version":1,"operation":"status","identity":{"source":"external","identifier":"x"}}"#,
            name: "operation-specific body shape is closed"
        )
        expectSchemaError(
            .malformedBody,
            json: #"{"version":1,"operation":"status",}"#,
            name: "malformed JSON is rejected deterministically"
        )

        do {
            _ = try ActivityIntegrationCodec.decodeRequest(
                Data(repeating: 0x20, count: ActivityIntegrationAPI.maximumRequestBodyBytes + 1)
            )
            check(false, "oversized body is rejected")
        } catch let error as ActivityIntegrationSchemaError {
            check(
                error == .bodyTooLarge(maximumBytes: ActivityIntegrationAPI.maximumRequestBodyBytes),
                "oversized body returns the fixed size error"
            )
        } catch {
            recordUnexpected(error, context: "oversized body")
        }

        let hostileField = String(repeating: "x", count: 100) + "\u{001B}[31m"
        let diagnostic = ActivityIntegrationSchemaError.unknownField(hostileField).description
        check(diagnostic.utf8.count < 100, "unknown-field diagnostics are bounded")
        check(!diagnostic.contains("\u{001B}"), "unknown-field diagnostics remove terminal controls")

        do {
            let invalid = try ActivityIntegrationRequest(
                operation: .submit,
                activity: ActivityIntegrationPayload(
                    identifier: "bad",
                    source: "\u{001B}[31m",
                    kind: "generic",
                    priority: 50,
                    title: "Bad"
                )
            )
            let response = await controller.handle(invalid)
            check(response.error?.code == .invalidRequest, "unknown schema value is rejected")
            check(response.error?.message == "source contains an unknown value", "unknown value is not echoed")
        } catch {
            recordUnexpected(error, context: "sanitized validation response")
        }
    }

    func verifyURLRoute() async {
        let route = URLActivityIntegrationRoute(handler: ActivityIntegrationController())
        do {
            let response = await route.handle(
                try requireURL(
                    "erylo://v1/submit?requestIdentifier=url-1&identifier=url-item&source=external&kind=generic&priority=50&title=Hello%20Erylo"
                )
            )
            check(response.isSuccess, "versioned URL submit succeeds")
            check(response.result?.snapshot.current?.title == "Hello Erylo", "URL value decodes after raw validation")
            let status = await route.handle(try requireURL("erylo://v1/status"))
            check(status.result?.snapshot.current?.identifier == "url-item", "versioned URL status succeeds")
        } catch {
            recordUnexpected(error, context: "valid URL route")
        }

        let rejectedURLs = [
            "erylo://v%31/status",
            "erylo://v1/st%61tus",
            "erylo://v1/status?requestIdent%69fier=x",
            "erylo://v1/status?requestIdentifier=a%26operation=cancel",
            "erylo://v1/status?requestIdentifier=a%3doperation",
            "erylo://v1/status?requestIdentifier=a+value",
            "erylo://v1/status?",
            "erylo://v1/status?requestIdentifier=a&requestIdentifier=b",
            "erylo://v1/status?command=whoami",
            "erylo://v1/launch?command=whoami",
            "ERYLO://v1/status",
        ]
        for rawURL in rejectedURLs {
            do {
                let response = await route.handle(try requireURL(rawURL))
                check(response.error != nil, "URL route rejects hostile encoded or unknown structure")
            } catch {
                recordUnexpected(error, context: "construct hostile URL")
            }
        }
    }

    func verifyCommandLineRoute() async {
        let route = CommandLineActivityIntegrationRoute(handler: ActivityIntegrationController())
        let submit = await route.handle([
            "v1", "submit", "--request-id", "cli-1", "--identifier", "cli-item",
            "--source", "external", "--kind", "generic", "--priority", "75",
            "--title", "CLI activity", "--ttl-ms", "1000",
        ])
        check(submit.isSuccess, "versioned command-line submit succeeds")
        check(submit.result?.snapshot.current?.identifier == "cli-item", "CLI parser builds the closed request")
        check((await route.handle(["v1", "status"])).isSuccess, "versioned command-line status succeeds")
        check(
            (await route.handle([
                "v1", "cancel", "--source", "external", "--identifier", "cli-item",
            ])).result?.cancelled == true,
            "versioned command-line cancel succeeds"
        )

        let invalidInputs = [
            ["v2", "status"],
            ["v1", "launch", "--command", "whoami"],
            ["v1", "status", "--command", "whoami"],
            ["v1", "status", "--request-id", "a", "--request-id", "b"],
            ["v1", "submit", "--identifier"],
            ["v1", "submit", "identifier", "x"],
        ]
        for arguments in invalidInputs {
            check((await route.handle(arguments)).error != nil, "CLI route rejects non-allowlisted input")
        }
        let oversized = String(repeating: "x", count: ActivityIntegrationAPI.maximumCommandLineBytes)
        check(
            (await route.handle(["v1", "status", "--request-id", oversized])).error?.code == .invalidRequest,
            "CLI subtract-before-add byte accounting rejects oversized input"
        )
    }

    func verifyFraming() {
        do {
            let first = Data(#"{"version":1,"operation":"status"}"#.utf8)
            let second = Data(#"{"version":1,"operation":"cancel","identity":{"source":"external","identifier":"x"}}"#.utf8)
            let firstFrame = try LengthPrefixedFrameDecoder.encode(
                first,
                maximumBodyBytes: ActivityIntegrationAPI.maximumRequestBodyBytes
            )
            let secondFrame = try LengthPrefixedFrameDecoder.encode(
                second,
                maximumBodyBytes: ActivityIntegrationAPI.maximumRequestBodyBytes
            )
            var decoder = LengthPrefixedFrameDecoder()
            check(try decoder.append(firstFrame.prefix(3)).isEmpty, "partial prefix yields no frame")
            var combined = Data(firstFrame.dropFirst(3))
            combined.append(secondFrame)
            check(try decoder.append(combined) == [first, second], "partial and multiple frames decode in order")
            try decoder.finish()

            var truncated = LengthPrefixedFrameDecoder()
            _ = try truncated.append(firstFrame.dropLast())
            do {
                try truncated.finish()
                check(false, "truncated frame is rejected")
            } catch let error as LengthPrefixedFrameError {
                check(error == .truncatedFrame, "truncated frame returns typed error")
            }

            var oversized = LengthPrefixedFrameDecoder()
            let length = UInt32(ActivityIntegrationAPI.maximumRequestBodyBytes + 1)
            do {
                _ = try oversized.append(framePrefix(length))
                check(false, "oversized frame prefix is rejected immediately")
            } catch let error as LengthPrefixedFrameError {
                check(
                    error == .frameTooLarge(maximumBytes: ActivityIntegrationAPI.maximumRequestBodyBytes),
                    "oversized frame returns typed bound"
                )
            }
        } catch {
            recordUnexpected(error, context: "frame decoder")
        }
    }

    private func expectSchemaError(
        _ expected: ActivityIntegrationSchemaError,
        json: String,
        name: String
    ) {
        do {
            _ = try ActivityIntegrationCodec.decodeRequest(Data(json.utf8))
            check(false, name)
        } catch let error as ActivityIntegrationSchemaError {
            check(error == expected, name)
        } catch {
            recordUnexpected(error, context: name)
        }
    }

    private func requireURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw HarnessError.invalidURL }
        return url
    }

}
