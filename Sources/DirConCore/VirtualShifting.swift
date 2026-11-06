import Foundation

public enum Strategy: Equatable {
    case undecided, circumference, transform
}

/// Virtual Shimano shifting as a pipeline interceptor (shifting spec, "FTMS interface" and
/// "Control strategies"). The proxy owns trainer control; Zwift's Request Control, SIM and
/// wheel-circumference writes are answered locally, and the trainer gets the proxy's own writes,
/// one Control Point procedure at a time.
public final class VirtualShifting: Interceptor {
    public let config: ShiftingConfig
    public let ladder: GearLadder
    public private(set) var gearIndex: Int
    public private(set) var strategy: Strategy = .undecided
    public private(set) var baseCircumferenceMM: Double
    public var gear: Gear { ladder.gears[gearIndex] }

    private enum Mode { case none, sim, erg }

    private let status: (String) -> Void
    private let log: (String) -> Void
    private weak var control: ProxyControl?

    private var mode = Mode.none
    private var road: SimParams?
    private var trainerReady = false

    // Work waiting for the Control Point, done in this order.
    private var needControl = false
    private var needProbe = false
    private var needRoad = false   // SIM parameters (transform: whole state; circumference: Zwift's raw 0x11)
    private var needGear = false   // circumference only: 0x12 = L × k

    private struct InFlight {
        let op: UInt8
        let value: Data
        var attempt: Int
        var timer: Cancellable?
    }
    private var inFlight: InFlight?
    private var suppressStatus = false
    private var suppressTimer: Cancellable?

    public static let indicationTimeout = 1.0
    public static let statusWindow = 1.0

    public init(config: ShiftingConfig, status: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.config = config
        self.ladder = config.ladder
        self.status = status
        self.log = log
        self.baseCircumferenceMM = config.wheelCircumferenceMM
        switch config.start {
        case .identity: gearIndex = ladder.identityIndex
        case .number(let n): gearIndex = max(0, min(ladder.gears.count - 1, n - 1))
        }
        if config.strategy == .transform { strategy = .transform }
    }

    // MARK: Shifting

    public func shift(_ d: ShiftDirection) {
        let next = gearIndex + (d == .up ? 1 : -1)
        guard ladder.gears.indices.contains(next) else {
            log("gear limit: \(ladder.statusLine(gear))")
            return
        }
        gearIndex = next
        status(ladder.statusLine(gear))
        guard mode == .sim else { return }
        if strategy == .circumference { needGear = true } else { needRoad = true }
        pump()
    }

    // MARK: Interceptor

    public func attach(_ control: ProxyControl) { self.control = control }

    public func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict {
        guard ch == FTMSUUID.controlPointID, let cmd = ControlCommand(value) else { return .forward(value) }
        switch cmd {
        case .requestControl:
            return answer(cmd)
        case .simulation(let p):
            road = p
            mode = .sim
            needRoad = true
            if strategy == .circumference { needGear = true }
            defer { pump() }
            return answer(cmd)
        case .wheelCircumference(let c):
            baseCircumferenceMM = Double(c) / 10
            if mode == .sim, strategy == .circumference { needGear = true }
            defer { pump() }
            return answer(cmd)
        case .setTargetPower:
            mode = .erg
            return .forward(value)
        default:
            return .forward(value)
        }
    }

    public func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict {
        if ch == FTMSUUID.statusID, let op = value.first, op == 0x12 || op == 0x13, suppressStatus {
            return .drop
        }
        guard ch == FTMSUUID.controlPointID, let r = ControlResponse(value) else { return .forward(value) }
        if let f = inFlight, f.op == r.requestOp {
            completeOwnWrite(result: r.result)
            return .drop
        }
        if r.requestOp == 0x01, r.result == ControlResponse.success {
            // Zwift's Reset succeeded: take control again and re-apply the gear.
            needControl = true
            needRoad = mode == .sim
            needGear = mode == .sim && strategy == .circumference
            pump()
        }
        return .forward(value)
    }

    public func readResult(_ ch: CharacteristicID, _ value: Data) -> Data {
        ch == FTMSUUID.featureID ? FeatureBits.forZwift(value) : value
    }

    public func trainerStateChanged(_ s: TrainerState) {
        inFlight?.timer?.cancel()
        inFlight = nil
        trainerReady = s == .ready
        guard trainerReady else { return }
        needControl = true
        needProbe = strategy == .undecided
        needRoad = mode == .sim
        needGear = mode == .sim && strategy == .circumference
        pump()
    }

    // MARK: Control Point writes

    /// Answer Zwift locally: DirCon success plus the `80 op 01` indication it waits for.
    private func answer(_ cmd: ControlCommand) -> Verdict {
        control?.notifyClients(FTMSUUID.controlPointID,
                               ControlResponse(requestOp: cmd.opCode, result: ControlResponse.success).encoded())
        return .reply(.success)
    }

    private func pump() {
        guard trainerReady, inFlight == nil, control != nil else { return }
        if needControl {
            needControl = false
            return send(.requestControl)
        }
        if needProbe {
            needProbe = false
            let feature = control?.cachedValue(FTMSUUID.featureID) ?? Data()
            let bit14 = FeatureBits.targetSettings(feature) & (1 << 14) != 0
            if config.strategy != .transform, bit14 {
                return send(.wheelCircumference(UInt16((baseCircumferenceMM * 10).rounded())))
            }
            strategy = .transform
            log("strategy: parameter transform")
        }
        guard strategy != .undecided, mode == .sim, let road else {
            needRoad = false
            needGear = false
            return
        }
        if needRoad {
            needRoad = false
            if strategy == .transform {
                return send(.simulation(Physics.strategyB(RoadState(road), k: gear.k, maxGradePct: config.maxGradePct)))
            }
            return send(.simulation(road))
        }
        if needGear {
            needGear = false
            let c = (baseCircumferenceMM * gear.k * 10).rounded()
            return send(.wheelCircumference(UInt16(max(1, min(65535, c)))))
        }
    }

    private func send(_ cmd: ControlCommand) {
        let value = cmd.encoded()
        inFlight = InFlight(op: cmd.opCode, value: value, attempt: 0, timer: nil)
        transmit()
    }

    private func transmit() {
        guard var f = inFlight, let control else { return }
        suppressTimer?.cancel()
        suppressStatus = true
        log("proxy → trainer: \(ControlCommand(f.value).map(describe) ?? "?")")
        control.sendToTrainer(FTMSUUID.controlPointID, f.value) { [weak self] r in
            guard let self, case .failure(let e) = r, self.inFlight?.op == f.op else { return }
            self.log("own write failed: \(e)")
            self.finish()
        }
        f.timer = control.scheduler.after(Self.indicationTimeout) { [weak self] in self?.timedOut() }
        inFlight = f
    }

    private func timedOut() {
        guard var f = inFlight else { return }
        if f.attempt == 0 {
            f.attempt = 1
            inFlight = f
            log("no indication; retrying")
            transmit()
        } else {
            status("trainer link degraded")
            finish()
        }
    }

    private func completeOwnWrite(result: UInt8) {
        guard let f = inFlight else { return }
        if result != ControlResponse.success {
            log(String(format: "trainer rejected op 0x%02X with %d", f.op, result))
        }
        if f.op == 0x12, strategy == .undecided {
            strategy = result == ControlResponse.success ? .circumference : .transform
            log(strategy == .circumference ? "strategy: wheel circumference" : "strategy: parameter transform")
            if strategy == .circumference, mode == .sim { needGear = true }
        }
        finish()
    }

    private func finish() {
        inFlight?.timer?.cancel()
        inFlight = nil
        suppressTimer = control?.scheduler.after(Self.statusWindow) { [weak self] in self?.suppressStatus = false }
        pump()
    }
}
