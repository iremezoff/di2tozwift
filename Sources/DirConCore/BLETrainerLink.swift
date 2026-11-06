import CoreBluetooth
import Foundation

public enum BluetoothError: Error, CustomStringConvertible {
    case poweredOff, unauthorized, unsupported
    public var description: String {
        switch self {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied: allow your terminal app in System Settings › Privacy & Security › Bluetooth"
        case .unsupported: return "Bluetooth LE is not supported on this Mac"
        }
    }
}

public enum TrainerTarget: Equatable {
    case identifier(UUID)
    case name(String)
    case first

    /// A UUID string becomes `.identifier`, anything else `.name`.
    public init(_ s: String?) {
        guard let s, !s.isEmpty else { self = .first; return }
        self = UUID(uuidString: s).map { .identifier($0) } ?? .name(s)
    }
}

extension BLEUUID {
    init(_ cb: CBUUID) {
        let d = [UInt8](cb.data)
        switch d.count {
        case 2: self.init(short: UInt16(d[0]) << 8 | UInt16(d[1]))
        case 4:
            var b = BLEUUID.sigBase
            b[0] = d[0]; b[1] = d[1]; b[2] = d[2]; b[3] = d[3]
            self.init(bytes: b)!
        default: self.init(bytes: d)!
        }
    }

    var cbuuid: CBUUID { CBUUID(data: short.map { Data([UInt8($0 >> 8), UInt8($0 & 0xFF)]) } ?? data) }
}

extension CharProps {
    init(_ p: CBCharacteristicProperties) {
        var v: CharProps = []
        if p.contains(.read) { v.insert(.read) }
        if p.contains(.write) { v.insert(.write) }
        if p.contains(.writeWithoutResponse) { v.insert(.writeWithoutResponse) }
        if p.contains(.notify) { v.insert(.notify) }
        if p.contains(.indicate) { v.insert(.indicate) }
        self = v
    }
}

/// CoreBluetooth central for one FTMS trainer: GATT cache, serial operation queue with timeouts,
/// Control Point indications always on, and reconnect. Everything runs on the core queue.
public final class BLETrainerLink: NSObject, TrainerLink, CBCentralManagerDelegate, CBPeripheralDelegate {
    public weak var delegate: TrainerLinkDelegate?
    public private(set) var state: TrainerState = .scanning
    public private(set) var services: [GattService] = []
    public var name: String { peripheral?.name ?? lastName ?? "trainer" }
    public var identifier: String { peripheral?.identifier.uuidString ?? "" }
    public var onBluetoothError: ((BluetoothError) -> Void)?

    public static let operationTimeout = 2.0
    public static let offlineAfter = 30.0
    public static let notFoundHintAfter = 10.0

    private let target: TrainerTarget
    private let queue: DispatchQueue
    private let scheduler: Scheduler
    private let status: (String) -> Void
    private let log: (String) -> Void

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var lastName: String?
    private var chars: [CharacteristicID: CBCharacteristic] = [:]
    private var cache: [CharacteristicID: Data] = [:]
    private var pendingCharDiscovery = 0
    private var pendingSetupReads: Set<CharacteristicID> = []
    private var controlPointIndicating = false
    private var stopping = false
    private var everReady = false
    private var hintTimer: Cancellable?
    private var offlineTimer: Cancellable?
    private var setupTimer: Cancellable?
    public static let setupTimeout = 10.0
    private var activity: NSObjectProtocol?

    private enum OpKind { case read, write(Data) }
    private struct Op {
        let id: CharacteristicID
        let kind: OpKind
        let readDone: ((Result<Data, TrainerError>) -> Void)?
        let writeDone: ((Result<Void, TrainerError>) -> Void)?
    }
    private var ops: [Op] = []
    private var opTimer: Cancellable?

    public init(target: TrainerTarget, queue: DispatchQueue, scheduler: Scheduler,
                status: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.target = target
        self.queue = queue
        self.scheduler = scheduler
        self.status = status
        self.log = log
    }

    // MARK: TrainerLink

    public func cachedValue(_ id: CharacteristicID) -> Data? { cache[id] }

    public func start() {
        stopping = false
        if let c = central, c.state == .poweredOn { begin() } else if central == nil {
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    public func stop() {
        stopping = true
        hintTimer?.cancel()
        offlineTimer?.cancel()
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        endActivity()
        setState(.offline)
        failAll(.offline)
    }

    public func read(_ id: CharacteristicID, completion: @escaping (Result<Data, TrainerError>) -> Void) {
        guard state == .ready, chars[id] != nil else { return completion(.failure(.offline)) }
        enqueue(Op(id: id, kind: .read, readDone: completion, writeDone: nil))
    }

    public func write(_ id: CharacteristicID, _ value: Data, completion: @escaping (Result<Void, TrainerError>) -> Void) {
        guard state == .ready, chars[id] != nil else { return completion(.failure(.offline)) }
        enqueue(Op(id: id, kind: .write(value), readDone: nil, writeDone: completion))
    }

    public func setNotify(_ id: CharacteristicID, _ on: Bool) {
        guard id != FTMSUUID.controlPointID, let c = chars[id], let p = peripheral, state == .ready else { return }
        p.setNotifyValue(on, for: c)
    }

    // MARK: Central

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: if !stopping, peripheral == nil { begin() }
        case .unauthorized: onBluetoothError?(.unauthorized)
        case .poweredOff: onBluetoothError?(.poweredOff)
        case .unsupported: onBluetoothError?(.unsupported)
        default: break
        }
    }

    private func begin() {
        guard let central else { return }
        setState(.scanning)
        if case .identifier(let id) = target, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            log("retrieved known trainer \(id)")
            connect(p)
        } else {
            log("scanning for FTMS trainers")
            central.scanForPeripherals(withServices: [FTMSUUID.service.cbuuid], options: nil)
        }
        scheduleNotFoundHint()
    }

    private func scheduleNotFoundHint() {
        hintTimer?.cancel()
        hintTimer = scheduler.after(Self.notFoundHintAfter) { [weak self] in
            guard let self, self.state != .ready, !self.stopping else { return }
            self.status("trainer not found: spin the trainer to wake it")
            self.scheduleNotFoundHint()
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi: NSNumber) {
        let advName = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        switch target {
        case .first: break
        case .identifier(let id): guard p.identifier == id else { return }
        case .name(let n): guard advName?.caseInsensitiveCompare(n) == .orderedSame else { return }
        }
        c.stopScan()
        lastName = advName
        log("found \(advName ?? "-") (\(p.identifier.uuidString)) \(rssi) dBm")
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        lastName = p.name ?? lastName
        p.delegate = self
        if state == .scanning { setState(.connecting) }
        central?.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected; discovering services")
        chars = [:]
        controlPointIndicating = false
        p.discoverServices(nil)
        setupTimer?.cancel()
        setupTimer = scheduler.after(Self.setupTimeout) { [weak self] in
            guard let self, self.state != .ready, p.state == .connected else { return }
            self.log("setup did not finish in \(Int(Self.setupTimeout)) s; reconnecting")
            self.central?.cancelPeripheralConnection(p)
        }
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "unknown"); retrying")
        c.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        setupTimer?.cancel()
        guard !stopping else { return failAll(.offline) }
        log("disconnected: \(error?.localizedDescription ?? "no error")")
        setState(.reconnecting)  // first, so completions below don't start new writes on a dead link
        failAll(.offline)
        status("trainer link lost: reconnecting (spin the trainer if it sleeps)")
        c.connect(p, options: nil)  // never times out; waits for the trainer
        offlineTimer?.cancel()
        offlineTimer = scheduler.after(Self.offlineAfter) { [weak self] in
            guard let self, self.state == .reconnecting else { return }
            self.setState(.offline)
            self.status("trainer offline: still trying to reconnect")
        }
        scheduleNotFoundHint()
    }

    // MARK: Discovery

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let list = p.services ?? []
        pendingCharDiscovery = list.count
        if error != nil || list.isEmpty {
            log("service discovery failed: \(error?.localizedDescription ?? "no services"); reconnecting")
            central?.cancelPeripheralConnection(p)
            return
        }
        for s in list { p.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        pendingCharDiscovery -= 1
        guard pendingCharDiscovery == 0 else { return }

        var built: [GattService] = []
        for svc in p.services ?? [] {
            let su = BLEUUID(svc.uuid)
            var list: [GattCharacteristic] = []
            for c in svc.characteristics ?? [] {
                let cu = BLEUUID(c.uuid)
                list.append(GattCharacteristic(uuid: cu, props: CharProps(c.properties)))
                let id = CharacteristicID(service: su, characteristic: cu)
                if chars[id] == nil { chars[id] = c }
            }
            built.append(GattService(uuid: su, characteristics: list))
        }
        if everReady, built.map(\.uuid) != services.map(\.uuid) {
            log("trainer GATT changed after reconnect")
        }
        services = built

        // Cache every readable characteristic of the allowlisted services: they are static
        // (features, ranges, device information, sensor location).
        pendingSetupReads = []
        for (id, c) in chars where c.properties.contains(.read) {
            guard let s = id.service.short, GattModel.allowlist.contains(s) else { continue }
            if everReady, cache[id] != nil { continue }
            pendingSetupReads.insert(id)
            p.readValue(for: c)
        }
        if let cp = chars[FTMSUUID.controlPointID] {
            p.setNotifyValue(true, for: cp)
        } else {
            log("trainer has no FTMS Control Point")
            controlPointIndicating = true
        }
        scheduler.after(Self.operationTimeout) { [weak self] in
            guard let self, self.state != .ready, !self.pendingSetupReads.isEmpty else { return }
            self.log("setup reads timed out: \(self.pendingSetupReads.map(\.description).sorted())")
            self.pendingSetupReads = []
            self.becomeReadyIfSetUp()
        }
        becomeReadyIfSetUp()
    }

    private func becomeReadyIfSetUp() {
        guard state != .ready, pendingCharDiscovery == 0, pendingSetupReads.isEmpty, controlPointIndicating else { return }
        hintTimer?.cancel()
        offlineTimer?.cancel()
        setupTimer?.cancel()
        everReady = true
        beginActivity()
        setState(.ready)
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        let id = idFor(c)
        if let error { log("notify \(id.map(\.description) ?? "?") failed: \(error.localizedDescription)") }
        if id == FTMSUUID.controlPointID {
            // Even if enabling failed, carry on: writes still work and the log says why results are missing.
            controlPointIndicating = true
            becomeReadyIfSetUp()
        }
    }

    // MARK: Values and operations

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let id = idFor(c) else { return }
        let value = c.value ?? Data()
        if pendingSetupReads.contains(id) {
            pendingSetupReads.remove(id)
            if error == nil { cache[id] = value }
            becomeReadyIfSetUp()
            return
        }
        if let head = ops.first, head.id == id, case .read = head.kind {
            finishHead { $0.readDone?(error == nil ? .success(value) : .failure(.failed(error!.localizedDescription))) }
            return
        }
        guard error == nil else { return }
        delegate?.trainerValue(value, for: id)
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard let id = idFor(c), let head = ops.first, head.id == id, case .write = head.kind else { return }
        finishHead { $0.writeDone?(error == nil ? .success(()) : .failure(.failed(error!.localizedDescription))) }
    }

    private func idFor(_ c: CBCharacteristic) -> CharacteristicID? {
        guard let s = c.service else { return nil }
        let id = CharacteristicID(service: BLEUUID(s.uuid), characteristic: BLEUUID(c.uuid))
        return chars[id] === c ? id : chars.first { $0.value === c }?.key
    }

    private func enqueue(_ op: Op) {
        ops.append(op)
        if ops.count == 1 { runHead() }
    }

    private func runHead() {
        guard let op = ops.first else { return }
        guard let p = peripheral, p.state == .connected, let c = chars[op.id], state == .ready else {
            return finishHead { $0.readDone?(.failure(.offline)); $0.writeDone?(.failure(.offline)) }
        }
        switch op.kind {
        case .read:
            p.readValue(for: c)
        case .write(let v):
            if c.properties.contains(.write) {
                p.writeValue(v, for: c, type: .withResponse)
            } else {
                p.writeValue(v, for: c, type: .withoutResponse)
                return finishHead { $0.writeDone?(.success(())) }
            }
        }
        opTimer = scheduler.after(Self.operationTimeout) { [weak self] in
            self?.log("BLE operation on \(op.id) timed out")
            self?.finishHead { $0.readDone?(.failure(.timeout)); $0.writeDone?(.failure(.timeout)) }
        }
    }

    private func finishHead(_ complete: (Op) -> Void) {
        opTimer?.cancel()
        opTimer = nil
        guard !ops.isEmpty else { return }
        let op = ops.removeFirst()
        complete(op)
        runHead()
    }

    private func failAll(_ e: TrainerError) {
        opTimer?.cancel()
        let pending = ops
        ops = []
        for op in pending {
            op.readDone?(.failure(e))
            op.writeDone?(.failure(e))
        }
    }

    // MARK: State

    private func setState(_ s: TrainerState) {
        guard s != state else { return }
        state = s
        delegate?.trainerStateChanged(s)
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Relaying a smart trainer to Zwift")
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }
}

/// One-off scan for `dirconproxy scan`: FTMS trainers in range, strongest first.
public final class BLEScanner: NSObject, CBCentralManagerDelegate {
    public struct Found { public let id: UUID; public let name: String; public let rssi: Int }

    private var central: CBCentralManager?
    private var found: [UUID: Found] = [:]
    private var seconds = 10.0
    private var queue = DispatchQueue.main
    private var completion: ((Result<[Found], BluetoothError>) -> Void)?

    public override init() {}

    public func scan(seconds: Double, queue: DispatchQueue, completion: @escaping (Result<[Found], BluetoothError>) -> Void) {
        self.seconds = seconds
        self.queue = queue
        self.completion = completion
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            c.scanForPeripherals(withServices: [FTMSUUID.service.cbuuid], options: nil)
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                c.stopScan()
                self.finish(.success(self.found.values.sorted { $0.rssi > $1.rssi }))
            }
        case .unauthorized: finish(.failure(.unauthorized))
        case .poweredOff: finish(.failure(.poweredOff))
        case .unsupported: finish(.failure(.unsupported))
        default: break
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "-"
        let r = rssi.intValue == 127 ? (found[p.identifier]?.rssi ?? -127) : rssi.intValue
        found[p.identifier] = Found(id: p.identifier, name: name, rssi: r)
    }

    private func finish(_ r: Result<[Found], BluetoothError>) {
        guard let c = completion else { return }
        completion = nil
        c(r)
    }
}
