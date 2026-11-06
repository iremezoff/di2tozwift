import Foundation
@testable import DirConCore

/// Manual clock: work runs only inside `advance(by:)`, in time order.
final class TestScheduler: Scheduler {
    private final class Item: Cancellable {
        let at: Double
        let seq: Int
        var work: (() -> Void)?
        init(at: Double, seq: Int, work: @escaping () -> Void) { self.at = at; self.seq = seq; self.work = work }
        func cancel() { work = nil }
    }

    private(set) var now: Double = 0
    private var items: [Item] = []
    private var seq = 0

    func after(_ seconds: Double, _ work: @escaping () -> Void) -> Cancellable {
        seq += 1
        let item = Item(at: now + max(0, seconds), seq: seq, work: work)
        items.append(item)
        return item
    }

    func advance(by seconds: Double) {
        let end = now + seconds
        while let next = items.filter({ $0.at <= end }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            items.removeAll { $0 === next }
            now = next.at
            next.work?()
        }
        now = end
    }
}

/// Drives a ProxyCore over a SimulatedTrainer and records every frame each client receives.
final class Harness {
    let sched = TestScheduler()
    let trainer: SimulatedTrainer
    let core: ProxyCore
    var statuses: [String] = []
    var closed: [ClientID] = []
    private var parsers: [ClientID: FrameParser] = [:]
    private var inbox: [ClientID: [Frame]] = [:]

    init(interceptors: [Interceptor] = []) {
        trainer = SimulatedTrainer(scheduler: sched)
        var statusSink: (String) -> Void = { _ in }
        core = ProxyCore(trainer: trainer, interceptors: interceptors, scheduler: sched,
                         status: { statusSink($0) }, log: { _ in })
        statusSink = { [unowned self] in self.statuses.append($0) }
        core.onCloseClient = { [unowned self] in self.closed.append($0) }
        trainer.start()
        sched.advance(by: 0.1)
    }

    @discardableResult
    func connect(_ c: ClientID) -> Bool {
        parsers[c] = FrameParser()
        return core.clientConnected(c) { [unowned self] data in
            var p = self.parsers[c]!
            self.inbox[c, default: []] += try! p.append(data)
            self.parsers[c] = p
        }
    }

    func send(_ c: ClientID, _ type: MessageType, seq: UInt8, _ data: Data = Data()) {
        core.receive(Frame(type: type.rawValue, seq: seq, code: 0, data: data).encoded(), from: c)
        sched.advance(by: 0.05)
    }

    func write(_ c: ClientID, _ uuid: UInt16, _ value: String, seq: UInt8) {
        send(c, .writeCharacteristic, seq: seq, BLEUUID(short: uuid).data + hex(value))
    }

    func enable(_ c: ClientID, _ uuid: UInt16, _ on: Bool, seq: UInt8) {
        send(c, .enableNotifications, seq: seq, BLEUUID(short: uuid).data + Data([on ? 1 : 0]))
    }

    /// Frames received since the last call.
    func take(_ c: ClientID) -> [Frame] {
        defer { inbox[c] = [] }
        return inbox[c] ?? []
    }

    /// Values of notifications for `uuid` in `frames`.
    static func notifications(_ frames: [Frame], _ uuid: UInt16) -> [Data] {
        frames.filter { $0.type == MessageType.notification.rawValue && $0.data.prefix(16) == BLEUUID(short: uuid).data }
            .map { Data($0.data.dropFirst(16)) }
    }

    func cpWrites() -> [Data] {
        trainer.writes.filter { $0.0 == FTMSUUID.controlPointID }.map(\.1)
    }
}
