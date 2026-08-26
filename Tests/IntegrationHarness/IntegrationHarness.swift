import Darwin
import EryloLocalIntegrations
import Foundation

final class IntegrationHarness {
    private var checkCount = 0
    private var failures: [String] = []

    func check(_ condition: Bool, _ name: String) {
        checkCount += 1
        if !condition { failures.append(name) }
    }

    func recordUnexpected(_ error: any Error, context: String) {
        checkCount += 1
        failures.append("\(context) produced unexpected error: \(error)")
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Integration harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        fputs("Integration harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

enum HarnessError: Error {
    case invalidURL
    case invalidFrame
    case systemCall(String, Int32)
}
