import Foundation

public enum NotificationSeq: String, Codable {
    case zero, counter
}

/// Answers DirCon requests from up to four clients using the trainer link and the pipeline.
/// Pure protocol logic: the DirCon server feeds it bytes and gets bytes back. Call on the core queue.
public final class ProxyCore: TrainerLinkDelegate, ProxyControl {
    public static let maxClients = 4

    private final class Client {
        let send: (Data) -> Void
        var parser = FrameParser()
        var queue: [Frame] = []
        var busy = false
        var subs: Set<CharacteristicID> = []
        var notifySeq: UInt8 = 0
        init(send: @escaping (Data) -> Void) { self.send = send }
    }

    private struct QueuedControl {
        let value: Data
        let fromClient: Bool
    }

    public let trainer: TrainerLink
    public let pipeline: Pipeline
    public let scheduler: Scheduler
    public var onCloseClient: ((ClientID) -> Void)?
    public var onTrainerStateChange: ((TrainerState) -> Void)?

    private let notificationSeq: NotificationSeq
    private let status: (String) -> Void
    private let log: (String) -> Void

    private(set) var model: GattModel?
    private var clients: [ClientID: Client] = [:]
    private var refCount: [CharacteristicID: Int] = [:]
    private(set) var owner: ClientID?
    private var everReady = false

    /// Control Point commands that reached the trainer most recently (ERG 0x05 or SIM 0x11), for replay.
    private var lastControl: Data?
    /// Commands accepted while reconnecting: newest per op code, in arrival order.
    private var queuedControl: [UInt8: QueuedControl] = [:]
    private var queuedOrder: [UInt8] = []
    /// Op codes whose next trainer result is swallowed (replayed commands Zwift did not send now).
    private var swallow: [UInt8: Int] = [:]

    /// Notifications produced by an interceptor during a write hook go out after that write's response.
    private var deferring = false
    private var deferred: [() -> Void] = []

    public init(trainer: TrainerLink, interceptors: [Interceptor], scheduler: Scheduler,
                notificationSeq: NotificationSeq = .zero,
                status: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.trainer = trainer
        self.pipeline = Pipeline(interceptors)
        self.scheduler = scheduler
        self.notificationSeq = notificationSeq
        self.status = status
        self.log = log
        trainer.delegate = self
        for i in interceptors { i.attach(self) }
    }

    // MARK: Clients

    /// false when four clients are already connected.
    public func clientConnected(_ c: ClientID, send: @escaping (Data) -> Void) -> Bool {
        guard clients.count < Self.maxClients else { return false }
        clients[c] = Client(send: send)
        return true
    }

    public func clientDisconnected(_ c: ClientID) {
        guard let client = clients.removeValue(forKey: c) else { return }
        for id in client.subs where id != FTMSUUID.controlPointID { release(id) }
        if owner == c {
            owner = nil
            status("control released")
        }
        for i in pipeline.interceptors { i.clientDisconnected(c) }
    }

    public func receive(_ data: Data, from c: ClientID) {
        guard let client = clients[c] else { return }
        do {
            client.queue += try client.parser.append(data)
        } catch {
            log("client \(c): \(error); closing")
            clientDisconnected(c)
            onCloseClient?(c)
            return
        }
        pump(c)
    }

    private func pump(_ c: ClientID) {
        while let client = clients[c], !client.busy, !client.queue.isEmpty {
            let frame = client.queue.removeFirst()
            client.busy = true
            handle(frame, from: c) { [weak self] response in
                guard let self, let client = self.clients[c] else { return }
                client.send(response.encoded())
                client.busy = false
                self.flushDeferred()
                self.pump(c)
            }
        }
    }

    // MARK: Requests

    private func handle(_ f: Frame, from c: ClientID, done: @escaping (Frame) -> Void) {
        func reply(_ code: ResponseCode, _ data: Data = Data()) { done(.response(to: f, code: code, data: data)) }

        guard let type = MessageType(rawValue: f.type), type != .notification else { return reply(.invalidMessageType) }
        guard let request = DirConRequest.decode(f) else { return reply(.genericError) }
        guard let model else { return reply(.genericError) }

        switch request {
        case .discoverServices:
            reply(.success, Data(model.exposedServices.flatMap(\.bytes)))

        case .discoverCharacteristics(let s):
            guard let chars = model.characteristics(of: s) else { return reply(.serviceNotFound) }
            reply(.success, s.data + Data(chars.flatMap { $0.uuid.bytes + [$0.dirconProps] }))

        case .read(let u):
            guard let id = model.resolve(u) else { return reply(.characteristicNotFound) }
            guard model.props(id)?.contains(.read) == true else { return reply(.operationNotSupported) }
            if let v = trainer.cachedValue(id) {
                return reply(.success, u.data + pipeline.readResult(id, v))
            }
            guard trainer.state == .ready else { return reply(.genericError) }
            trainer.read(id) { [weak self] r in
                guard let self else { return }
                switch r {
                case .success(let v): reply(.success, u.data + self.pipeline.readResult(id, v))
                case .failure: reply(.genericError)
                }
            }

        case .write(let u, let value):
            guard let id = model.resolve(u) else { return reply(.characteristicNotFound) }
            guard let p = model.props(id), !p.isDisjoint(with: [.write, .writeWithoutResponse]) else {
                return reply(.operationNotSupported)
            }
            if id == FTMSUUID.controlPointID {
                controlPointWrite(value, from: c, reply: { reply($0, u.data) })
            } else {
                guard trainer.state == .ready else { return reply(.genericError) }
                runPipeline(id, value, from: c) { code in reply(code, code == .success ? u.data : Data()) }
            }

        case .enableNotifications(let u, let on):
            guard let id = model.resolve(u) else { return reply(.characteristicNotFound) }
            guard let p = model.props(id), !p.isDisjoint(with: [.notify, .indicate]) else {
                return reply(.operationNotSupported)
            }
            guard let client = clients[c] else { return }
            if on, !client.subs.contains(id) {
                client.subs.insert(id)
                if id != FTMSUUID.controlPointID { retain(id) }
            } else if !on, client.subs.contains(id) {
                client.subs.remove(id)
                if id != FTMSUUID.controlPointID { release(id) }
            }
            reply(.success, u.data)
        }
    }

    private func controlPointWrite(_ value: Data, from c: ClientID, reply: @escaping (ResponseCode) -> Void) {
        let op = value.first ?? 0xFF
        if let o = owner, o != c {
            let denied = ControlResponse(requestOp: op, result: ControlResponse.notPermitted).encoded()
            deferred.append { [weak self] in self?.sendTo(c, FTMSUUID.controlPointID, denied) }
            reply(.success)
            return
        }
        if owner == nil, op == 0x00 {
            owner = c
            status("control granted")
        }
        switch trainer.state {
        case .ready:
            runPipeline(FTMSUUID.controlPointID, value, from: c, reply: reply)
        case .reconnecting:
            // Keep only the newest command per op code; it is replayed after reconnect.
            deferring = true
            let verdict = pipeline.clientWrite(FTMSUUID.controlPointID, value, from: c)
            deferring = false
            switch verdict {
            case .forward(let d):
                if queuedControl[op] == nil { queuedOrder.append(op) }
                queuedControl[op] = QueuedControl(value: d, fromClient: true)
                reply(.success)
            case .drop: reply(.success)
            case .reply(let code): reply(code)
            }
        default:
            reply(.genericError)
        }
    }

    /// Pipeline, then BLE write; the DirCon response goes out after the write completes.
    private func runPipeline(_ id: CharacteristicID, _ value: Data, from c: ClientID,
                             reply: @escaping (ResponseCode) -> Void) {
        deferring = true
        let verdict = pipeline.clientWrite(id, value, from: c)
        deferring = false
        switch verdict {
        case .drop: reply(.success)
        case .reply(let code): reply(code)
        case .forward(let d):
            trainer.write(id, d) { [weak self] r in
                switch r {
                case .success:
                    if id == FTMSUUID.controlPointID, let op = d.first, op == 0x05 || op == 0x11 { self?.lastControl = d }
                    reply(.success)
                case .failure(let e):
                    self?.log("write \(id) failed: \(e)")
                    reply(.writeFailed)
                }
            }
        }
    }

    // MARK: Subscriptions

    private func retain(_ id: CharacteristicID) {
        refCount[id, default: 0] += 1
        if refCount[id] == 1, trainer.state == .ready { trainer.setNotify(id, true) }
    }

    private func release(_ id: CharacteristicID) {
        guard let n = refCount[id], n > 0 else { return }
        refCount[id] = n - 1
        if n == 1 {
            refCount[id] = nil
            if trainer.state == .ready { trainer.setNotify(id, false) }
        }
    }

    // MARK: Trainer events

    public func trainerStateChanged(_ s: TrainerState) {
        switch s {
        case .ready:
            if model == nil { model = GattModel(services: trainer.services, log: log) }
            if everReady { restoreAfterReconnect() }
            everReady = true
        case .offline:
            for c in Array(clients.keys) {
                clientDisconnected(c)
                onCloseClient?(c)
            }
            queuedControl = [:]
            queuedOrder = []
        default:
            break
        }
        for i in pipeline.interceptors { i.trainerStateChanged(s) }
        onTrainerStateChange?(s)
    }

    private func restoreAfterReconnect() {
        for id in refCount.keys.sorted(by: { $0.description < $1.description }) { trainer.setNotify(id, true) }

        var plan: [QueuedControl] = []
        if let rc = queuedControl[0x00] {
            plan.append(rc)
        } else if !queuedOrder.isEmpty || lastControl != nil {
            plan.append(QueuedControl(value: Data([0x00]), fromClient: false))
        }
        for op in queuedOrder where op != 0x00 { plan.append(queuedControl[op]!) }
        if !queuedOrder.contains(where: { $0 == 0x05 || $0 == 0x11 }), let last = lastControl {
            plan.append(QueuedControl(value: last, fromClient: false))
        }
        queuedControl = [:]
        queuedOrder = []

        for item in plan {
            if !item.fromClient, let op = item.value.first { swallow[op, default: 0] += 1 }
            trainer.write(FTMSUUID.controlPointID, item.value) { [weak self] r in
                if case .success = r, let op = item.value.first, op == 0x05 || op == 0x11 { self?.lastControl = item.value }
            }
        }
    }

    public func trainerValue(_ value: Data, for id: CharacteristicID) {
        if id == FTMSUUID.controlPointID, let r = ControlResponse(value), let n = swallow[r.requestOp], n > 0 {
            swallow[r.requestOp] = n == 1 ? nil : n - 1
            log(String(format: "replayed op 0x%02X → %d", r.requestOp, r.result))
            return
        }
        guard case .forward(let v) = pipeline.trainerValue(id, value) else { return }
        deliver(id, v)
    }

    // MARK: ProxyControl

    public func sendToTrainer(_ ch: CharacteristicID, _ value: Data,
                              completion: @escaping (Result<Void, TrainerError>) -> Void) {
        guard trainer.state == .ready else { return completion(.failure(.offline)) }
        trainer.write(ch, value, completion: completion)
    }

    public func notifyClients(_ ch: CharacteristicID, _ value: Data) {
        if deferring { deferred.append { [weak self] in self?.deliver(ch, value) } } else { deliver(ch, value) }
    }

    public func cachedValue(_ ch: CharacteristicID) -> Data? { trainer.cachedValue(ch) }

    private func flushDeferred() {
        let items = deferred
        deferred = []
        for item in items { item() }
    }

    // MARK: Delivery

    private func deliver(_ id: CharacteristicID, _ value: Data) {
        if id == FTMSUUID.controlPointID {
            if let o = owner {
                sendTo(o, id, value)
            } else {
                for (c, client) in clients where client.subs.contains(id) { sendTo(c, id, value) }
            }
            return
        }
        for (c, client) in clients where client.subs.contains(id) { sendTo(c, id, value) }
    }

    private func sendTo(_ c: ClientID, _ id: CharacteristicID, _ value: Data) {
        guard let client = clients[c] else { return }
        var seq: UInt8 = 0
        if notificationSeq == .counter {
            client.notifySeq &+= 1
            seq = client.notifySeq
        }
        client.send(Frame.notification(id.characteristic, value, seq: seq).encoded())
    }
}
