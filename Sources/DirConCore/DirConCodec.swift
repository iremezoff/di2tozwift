import Foundation

public enum MessageType: UInt8 {
    case discoverServices = 1, discoverCharacteristics, readCharacteristic,
         writeCharacteristic, enableNotifications, notification
}

public enum ResponseCode: UInt8 {
    case success = 0, invalidMessageType, genericError, serviceNotFound,
         characteristicNotFound, operationNotSupported, writeFailed
}

public enum FrameError: Error, Equatable {
    case badVersion(UInt8)
    case tooLong(Int)
}

public let dirConVersion: UInt8 = 1
public let dirConMaxDataLength = 512

/// One DirCon message: 6-byte header plus data. `type` stays raw so unknown types can be answered.
public struct Frame: Equatable {
    public var type: UInt8
    public var seq: UInt8
    public var code: UInt8
    public var data: Data

    public init(type: UInt8, seq: UInt8, code: UInt8, data: Data) {
        self.type = type
        self.seq = seq
        self.code = code
        self.data = data
    }

    public func encoded() -> Data {
        var out = Data([dirConVersion, type, seq, code, UInt8(data.count >> 8), UInt8(data.count & 0xFF)])
        out.append(data)
        return out
    }

    public static func response(to request: Frame, code: ResponseCode, data: Data = Data()) -> Frame {
        Frame(type: request.type, seq: request.seq, code: code.rawValue, data: data)
    }

    public static func notification(_ uuid: BLEUUID, _ value: Data, seq: UInt8 = 0) -> Frame {
        Frame(type: MessageType.notification.rawValue, seq: seq, code: 0, data: uuid.data + value)
    }
}

/// Reassembles frames from a TCP byte stream: one read may hold several frames or part of one.
public struct FrameParser {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while buffer.count >= 6 {
            let b = [UInt8](buffer.prefix(6))
            guard b[0] == dirConVersion else { throw FrameError.badVersion(b[0]) }
            let length = Int(b[4]) << 8 | Int(b[5])
            guard length <= dirConMaxDataLength else { throw FrameError.tooLong(length) }
            guard buffer.count >= 6 + length else { break }
            let start = buffer.startIndex
            let body = Data(buffer[(start + 6)..<(start + 6 + length)])
            frames.append(Frame(type: b[1], seq: b[2], code: b[3], data: body))
            buffer = Data(buffer[(start + 6 + length)...])
        }
        return frames
    }
}

public enum DirConRequest: Equatable {
    case discoverServices
    case discoverCharacteristics(BLEUUID)
    case read(BLEUUID)
    case write(BLEUUID, Data)
    case enableNotifications(BLEUUID, Bool)

    /// nil for unknown message types or data too short for the type.
    public static func decode(_ f: Frame) -> DirConRequest? {
        guard let type = MessageType(rawValue: f.type) else { return nil }
        let d = [UInt8](f.data)
        let uuid = d.count >= 16 ? BLEUUID(bytes: d[0..<16]) : nil
        switch type {
        case .discoverServices:
            return .discoverServices
        case .discoverCharacteristics:
            return uuid.map { .discoverCharacteristics($0) }
        case .readCharacteristic:
            return uuid.map { .read($0) }
        case .writeCharacteristic:
            return uuid.map { .write($0, Data(d[16...])) }
        case .enableNotifications:
            guard let u = uuid, d.count >= 17 else { return nil }
            return .enableNotifications(u, d[16] != 0)
        case .notification:
            return nil
        }
    }
}
