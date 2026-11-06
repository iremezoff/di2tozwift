import Foundation

/// JSON Lines capture of every value crossing the pipeline, with millisecond timestamps, for replay tests.
public final class CaptureWriter {
    private let handle: FileHandle

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    deinit { try? handle.close() }

    public func record(direction: String, kind: String, uuid: BLEUUID?, data: Data) {
        let ms = Int((Date().timeIntervalSince1970 * 1000).rounded())
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let u = uuid.map { "\"\($0)\"" } ?? "null"
        let line = "{\"t\":\(ms),\"dir\":\"\(direction)\",\"kind\":\"\(kind)\",\"uuid\":\(u),\"hex\":\"\(hex)\"}\n"
        handle.write(Data(line.utf8))
    }
}

/// Records client writes, trainer values and read results; registered first so it sees Zwift's raw bytes.
public final class CaptureInterceptor: Interceptor {
    private let writer: CaptureWriter
    public init(_ writer: CaptureWriter) { self.writer = writer }

    public func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict {
        writer.record(direction: "zwift>trainer", kind: "write", uuid: ch.characteristic, data: value)
        return .forward(value)
    }

    public func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict {
        writer.record(direction: "trainer>zwift", kind: "notify", uuid: ch.characteristic, data: value)
        return .forward(value)
    }

    public func readResult(_ ch: CharacteristicID, _ value: Data) -> Data {
        writer.record(direction: "trainer>zwift", kind: "read", uuid: ch.characteristic, data: value)
        return value
    }
}

/// Debug-level hex dump of everything crossing the pipeline.
public final class HexDumpInterceptor: Interceptor {
    private let log: (String) -> Void
    public init(log: @escaping (String) -> Void) { self.log = log }
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

    public func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict {
        log("client \(client) write \(ch.characteristic): \(hex(value))")
        return .forward(value)
    }

    public func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict {
        log("trainer \(ch.characteristic): \(hex(value))")
        return .forward(value)
    }
}
