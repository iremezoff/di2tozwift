import Foundation

/// A software FTMS trainer with the T600's GATT layout, for testing without hardware.
/// Cadence is fixed; power follows the ERG target, or the road model in SIM mode.
public final class SimulatedTrainer: TrainerLink {
    public weak var delegate: TrainerLinkDelegate?
    public private(set) var state: TrainerState = .scanning
    public let name = "Simulated " + T600Profile.name
    public let identifier = "00000000-0000-0000-0000-00000000517A"
    public var services: [GattService] { T600Profile.services }

    public var cadenceRpm: Double
    public var massKg: Double
    /// Result code for each Control Point write; nil = never indicate (to test timeouts).
    public var respond: (ControlCommand) -> UInt8? = { cmd in
        cmd.opCode == 0x12 ? ControlResponse.notSupported : ControlResponse.success
    }

    public private(set) var writes: [(CharacteristicID, Data)] = []
    public private(set) var reads: [CharacteristicID] = []
    public private(set) var notifyCalls: [(CharacteristicID, Bool)] = []
    public private(set) var ergTargetW: Int16?
    public private(set) var road: RoadState?

    private let scheduler: Scheduler
    private var notifying: Set<CharacteristicID> = []
    private var ticker: Cancellable?

    public init(scheduler: Scheduler, cadenceRpm: Double = 85, massKg: Double = 85) {
        self.scheduler = scheduler
        self.cadenceRpm = cadenceRpm
        self.massKg = massKg
    }

    public func cachedValue(_ id: CharacteristicID) -> Data? { T600Profile.staticValues[id] }

    public func start() {
        setState(.connecting)
        scheduler.after(0.01) { [weak self] in self?.setState(.ready) }
    }

    public func stop() {
        ticker?.cancel()
        notifying = []
        setState(.offline)
    }

    public func simulateDisconnect() {
        notifying = []
        ticker?.cancel()
        setState(.reconnecting)
    }

    public func simulateReconnect() { setState(.ready) }

    public func read(_ id: CharacteristicID, completion: @escaping (Result<Data, TrainerError>) -> Void) {
        reads.append(id)
        let v = cachedValue(id)
        scheduler.after(0) { completion(v.map { .success($0) } ?? .failure(.failed("not readable"))) }
    }

    public func write(_ id: CharacteristicID, _ value: Data, completion: @escaping (Result<Void, TrainerError>) -> Void) {
        guard state == .ready else {
            scheduler.after(0) { completion(.failure(.offline)) }
            return
        }
        writes.append((id, value))
        scheduler.after(0) { completion(.success(())) }
        guard id == FTMSUUID.controlPointID, let cmd = ControlCommand(value) else { return }
        switch cmd {
        case .setTargetPower(let w): ergTargetW = w
        case .simulation(let p): road = RoadState(p); ergTargetW = nil
        case .reset: road = nil; ergTargetW = nil
        default: break
        }
        if let result = respond(cmd) {
            scheduler.after(0.005) { [weak self] in
                guard let self, self.state == .ready else { return }
                self.delegate?.trainerValue(ControlResponse(requestOp: cmd.opCode, result: result).encoded(),
                                            for: FTMSUUID.controlPointID)
            }
        }
    }

    public func setNotify(_ id: CharacteristicID, _ on: Bool) {
        notifyCalls.append((id, on))
        if on { notifying.insert(id) } else { notifying.remove(id) }
        if id == FTMSUUID.indoorBikeDataID {
            ticker?.cancel()
            if on { tick() }
        }
    }

    /// Physical speed: 52×14 on a 2105 mm wheel.
    public var speedMS: Double { Physics.trainerSpeed(cadenceRpm: cadenceRpm, ratio: 52.0 / 14.0, circumferenceMM: 2105) }

    public var powerW: Int {
        if let w = ergTargetW { return Int(w) }
        let r = road ?? RoadState(windMS: 0, gradePct: 0, crr: 0.004, cw: 0.51)
        return max(0, Int((Physics.roadForce(speed: speedMS, road: r, massKg: massKg) * speedMS).rounded()))
    }

    private func tick() {
        guard state == .ready, notifying.contains(FTMSUUID.indoorBikeDataID) else { return }
        let kmh = UInt16(max(0, min(65535, (speedMS * 3.6 * 100).rounded())))
        let cad = UInt16(max(0, min(65535, (cadenceRpm * 2).rounded())))
        let data = Data([0x44, 0x00] + le16(kmh) + le16(cad) + le16(Int16(clamping: powerW)))
        delegate?.trainerValue(data, for: FTMSUUID.indoorBikeDataID)
        ticker = scheduler.after(0.25) { [weak self] in self?.tick() }
    }

    private func setState(_ s: TrainerState) {
        state = s
        delegate?.trainerStateChanged(s)
    }
}
