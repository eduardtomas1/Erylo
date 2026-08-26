import Foundation

/// A bounded grammar pass that rejects duplicate decoded object keys before Codable sees the body.
enum StrictJSONPreflight {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw ActivityIntegrationSchemaError.malformedBody }
        }

        mutating func parseValue() throws {
            guard index < bytes.count else { throw ActivityIntegrationSchemaError.malformedBody }
            switch bytes[index] {
            case 0x7b: try parseObject()
            case 0x5b: try parseArray()
            case 0x22: _ = try parseString()
            case 0x74: try consumeLiteral("true")
            case 0x66: try consumeLiteral("false")
            case 0x6e: try consumeLiteral("null")
            case 0x2d, 0x30...0x39: try parseNumber()
            default: throw ActivityIntegrationSchemaError.malformedBody
            }
        }

        mutating func parseObject() throws {
            try enterContainer()
            defer { depth -= 1 }
            index += 1
            skipWhitespace()
            if consume(0x7d) { return }

            var keys: Set<String> = []
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw ActivityIntegrationSchemaError.malformedBody
                }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw ActivityIntegrationSchemaError.duplicateField(key)
                }
                skipWhitespace()
                guard consume(0x3a) else { throw ActivityIntegrationSchemaError.malformedBody }
                skipWhitespace()
                try parseValue()
                skipWhitespace()
                if consume(0x7d) { return }
                guard consume(0x2c) else { throw ActivityIntegrationSchemaError.malformedBody }
                skipWhitespace()
            }
        }

        mutating func parseArray() throws {
            try enterContainer()
            defer { depth -= 1 }
            index += 1
            skipWhitespace()
            if consume(0x5d) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consume(0x5d) { return }
                guard consume(0x2c) else { throw ActivityIntegrationSchemaError.malformedBody }
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    let token = Data(bytes[start..<index])
                    guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
                        throw ActivityIntegrationSchemaError.malformedBody
                    }
                    return decoded
                }
                if byte < 0x20 { throw ActivityIntegrationSchemaError.malformedBody }
                if byte == 0x5c {
                    index += 1
                    guard index < bytes.count else { throw ActivityIntegrationSchemaError.malformedBody }
                    if bytes[index] == 0x75 {
                        guard index + 4 < bytes.count,
                              bytes[(index + 1)...(index + 4)].allSatisfy(Self.isHexDigit) else {
                            throw ActivityIntegrationSchemaError.malformedBody
                        }
                        index += 5
                        continue
                    }
                    guard [0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(bytes[index]) else {
                        throw ActivityIntegrationSchemaError.malformedBody
                    }
                }
                index += 1
            }
            throw ActivityIntegrationSchemaError.malformedBody
        }

        mutating func parseNumber() throws {
            if consume(0x2d), index == bytes.count {
                throw ActivityIntegrationSchemaError.malformedBody
            }
            if consume(0x30) {
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw ActivityIntegrationSchemaError.malformedBody
                }
            } else {
                guard consumeDigits(requireOne: true) else {
                    throw ActivityIntegrationSchemaError.malformedBody
                }
            }
            if consume(0x2e), !consumeDigits(requireOne: true) {
                throw ActivityIntegrationSchemaError.malformedBody
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                _ = consume(0x2b) || consume(0x2d)
                guard consumeDigits(requireOne: true) else {
                    throw ActivityIntegrationSchemaError.malformedBody
                }
            }
        }

        mutating func consumeDigits(requireOne: Bool) -> Bool {
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            return !requireOne || index > start
        }

        mutating func consumeLiteral(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw ActivityIntegrationSchemaError.malformedBody
            }
            index += expected.count
        }

        mutating func enterContainer() throws {
            depth += 1
            guard depth <= 16 else { throw ActivityIntegrationSchemaError.malformedBody }
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        static func isHexDigit(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}
