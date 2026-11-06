import Foundation
import Network
import Testing
@testable import DirConCore

/// A server over a simulated trainer on a real queue, listening on an ephemeral port.
private final class LiveRig: @unchecked Sendable {
    let queue = DispatchQueue(label: "dircon.test")
    let trainer: SimulatedTrainer
    let core: ProxyCore
    let server: DirConServer

    init() {
        let sched = DispatchScheduler(queue: queue)
        trainer = SimulatedTrainer(scheduler: sched)
        core = ProxyCore(trainer: trainer, interceptors: [], scheduler: sched, status: { _ in }, log: { _ in })
        server = DirConServer(core: core, port: 0, queue: queue, status: { _ in })
        queue.sync { trainer.start() }
    }

    /// Waits for the simulated trainer to be ready (as the app does), then starts the listener.
    func start() async -> Result<UInt16, Error> {
        for _ in 0..<200 where queue.sync(execute: { trainer.state }) != .ready {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await withCheckedContinuation { c in
            queue.async { self.server.start { c.resume(returning: $0) } }
        }
    }
}

private func connect(_ port: UInt16) async throws -> NWConnection {
    let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let q = DispatchQueue(label: "client")
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        conn.stateUpdateHandler = { s in
            guard !once.done else { return }
            switch s {
            case .ready: once.done = true; c.resume()
            case .failed(let e): once.done = true; c.resume(throwing: e)
            default: break
            }
        }
        conn.start(queue: q)
    }
    return conn
}

private func send(_ conn: NWConnection, _ data: Data) {
    conn.send(content: data, completion: .contentProcessed { _ in })
}

/// Reads one DirCon frame (header, then the length it declares); nil if the connection closes first.
private func readFrame(_ conn: NWConnection) async -> Data? {
    guard let header = await read(conn, 6) else { return nil }
    let length = Int(header[header.startIndex + 4]) << 8 | Int(header[header.startIndex + 5])
    if length == 0 { return header }
    guard let body = await read(conn, length) else { return nil }
    return header + body
}

/// Reads exactly `count` bytes, or returns nil when the server closes the connection first.
private func read(_ conn: NWConnection, _ count: Int) async -> Data? {
    await withCheckedContinuation { c in
        conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
            if let data, data.count == count { c.resume(returning: data) } else { c.resume(returning: nil) }
            _ = (complete, error)
        }
    }
}

extension DirConServer: @unchecked Sendable {}

struct DirConServerTests {
    @Test func discoverOverTCP() async throws {
        let rig = LiveRig()
        let port = try await rig.start().get()
        let conn = try await connect(port)
        defer { conn.cancel(); rig.queue.sync { rig.server.stop() } }
        send(conn, hex("01 01 01 00 00 00"))
        let response = await readFrame(conn)
        let expected = Frame(type: 1, seq: 1, code: 0,
                             data: Data([0x180A, 0x1826, 0x1818, 0x1816].flatMap { BLEUUID(short: $0).bytes })).encoded()
        #expect(response == expected)
    }

    @Test func oversizedFrameClosesConnection() async throws {
        let rig = LiveRig()
        let port = try await rig.start().get()
        let conn = try await connect(port)
        defer { conn.cancel(); rig.queue.sync { rig.server.stop() } }
        send(conn, hex("01 03 01 00 02 58"))  // length 600
        #expect(await read(conn, 1) == nil)
    }

    @Test func portInUseFails() async throws {
        let first = LiveRig()
        let port = try await first.start().get()
        defer { first.queue.sync { first.server.stop() } }
        let second = LiveRig()
        let blocked = DirConServer(core: second.core, port: port, queue: second.queue, status: { _ in })
        let result = await withCheckedContinuation { c in
            second.queue.async { blocked.start { c.resume(returning: $0) } }
        }
        #expect(throws: (any Error).self) { try result.get() }
    }
}
