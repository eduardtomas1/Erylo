import Foundation

public enum LengthPrefixedFrameError: Error, Equatable, Sendable {
    case zeroLength
    case frameTooLarge(maximumBytes: Int)
    case inputChunkTooLarge(maximumBytes: Int)
    case truncatedFrame
}

/// Four-byte network-order length prefix followed by one UTF-8 JSON body.
public struct LengthPrefixedFrameDecoder: Sendable {
    private var buffer = Data()
    private let maximumBodyBytes: Int

    public init(maximumBodyBytes: Int = ActivityIntegrationAPI.maximumRequestBodyBytes) {
        precondition(maximumBodyBytes > 0 && maximumBodyBytes <= Int(UInt32.max))
        self.maximumBodyBytes = maximumBodyBytes
    }

    public var hasPartialFrame: Bool { !buffer.isEmpty }

    public mutating func append(_ data: Data) throws -> [Data] {
        let maximumChunkBytes = maximumBodyBytes + MemoryLayout<UInt32>.size
        guard data.count <= maximumChunkBytes else {
            throw LengthPrefixedFrameError.inputChunkTooLarge(maximumBytes: maximumChunkBytes)
        }
        buffer.append(data)

        var frames: [Data] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0 else { throw LengthPrefixedFrameError.zeroLength }
            guard length <= UInt32(maximumBodyBytes) else {
                throw LengthPrefixedFrameError.frameTooLarge(maximumBytes: maximumBodyBytes)
            }
            let completeLength = 4 + Int(length)
            guard buffer.count >= completeLength else { break }
            let bodyStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let bodyEnd = buffer.index(buffer.startIndex, offsetBy: completeLength)
            frames.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeFirst(completeLength)
        }
        return frames
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw LengthPrefixedFrameError.truncatedFrame }
    }

    public static func encode(_ body: Data, maximumBodyBytes: Int) throws -> Data {
        guard !body.isEmpty else { throw LengthPrefixedFrameError.zeroLength }
        guard body.count <= maximumBodyBytes, body.count <= Int(UInt32.max) else {
            throw LengthPrefixedFrameError.frameTooLarge(maximumBytes: maximumBodyBytes)
        }
        let length = UInt32(body.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        frame.append(body)
        return frame
    }
}
