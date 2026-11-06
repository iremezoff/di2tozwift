import Foundation

public typealias ClientID = Int

public protocol Cancellable {
    func cancel()
}

public protocol Scheduler {
    @discardableResult
    func after(_ seconds: Double, _ work: @escaping () -> Void) -> Cancellable
}

/// Production scheduler: runs work on the core queue.
public final class DispatchScheduler: Scheduler {
    private let queue: DispatchQueue
    public init(queue: DispatchQueue) { self.queue = queue }

    private final class Item: Cancellable {
        let work: DispatchWorkItem
        init(_ w: DispatchWorkItem) { work = w }
        func cancel() { work.cancel() }
    }

    public func after(_ seconds: Double, _ work: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return Item(item)
    }
}

public enum Verdict {
    case forward(Data)        // send on, possibly modified
    case drop                 // swallow silently (a write still gets DirCon success)
    case reply(ResponseCode)  // answer the client; the trainer is not touched (writes only)
}

/// Handed to each interceptor when it is registered.
public protocol ProxyControl: AnyObject {
    func sendToTrainer(_ ch: CharacteristicID, _ value: Data, completion: @escaping (Result<Void, TrainerError>) -> Void)
    /// Control Point values go to the controlling client only; others to their subscribers.
    func notifyClients(_ ch: CharacteristicID, _ value: Data)
    func cachedValue(_ ch: CharacteristicID) -> Data?
    var scheduler: Scheduler { get }
}

/// Hooks run on the core queue and must return quickly. Defaults pass everything through.
public protocol Interceptor: AnyObject {
    func attach(_ control: ProxyControl)
    /// Zwift → trainer: Write Characteristic requests.
    func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict
    /// Trainer → Zwift: notifications and indications.
    func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict
    /// Read results, cached or live.
    func readResult(_ ch: CharacteristicID, _ value: Data) -> Data
    func trainerStateChanged(_ s: TrainerState)
    func clientDisconnected(_ client: ClientID)
}

public extension Interceptor {
    func attach(_ control: ProxyControl) {}
    func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict { .forward(value) }
    func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict { .forward(value) }
    func readResult(_ ch: CharacteristicID, _ value: Data) -> Data { value }
    func trainerStateChanged(_ s: TrainerState) {}
    func clientDisconnected(_ client: ClientID) {}
}

/// Runs interceptors in registration order; the first `.drop` or `.reply` ends the chain.
public final class Pipeline {
    public let interceptors: [Interceptor]
    public init(_ interceptors: [Interceptor]) { self.interceptors = interceptors }

    func clientWrite(_ ch: CharacteristicID, _ value: Data, from c: ClientID) -> Verdict {
        var v = value
        for i in interceptors {
            switch i.clientWrite(ch, v, from: c) {
            case .forward(let d): v = d
            case let other: return other
            }
        }
        return .forward(v)
    }

    func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict {
        var v = value
        for i in interceptors {
            switch i.trainerValue(ch, v) {
            case .forward(let d): v = d
            case let other: return other
            }
        }
        return .forward(v)
    }

    func readResult(_ ch: CharacteristicID, _ value: Data) -> Data {
        interceptors.reduce(value) { $1.readResult(ch, $0) }
    }
}

// MARK: Built-in interceptors

/// Decodes Control Point traffic and status for the log.
public final class LoggingInterceptor: Interceptor {
    private let log: (String) -> Void
    private let verboseData: Bool
    public init(verboseData: Bool = false, log: @escaping (String) -> Void) {
        self.log = log
        self.verboseData = verboseData
    }

    public func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict {
        if ch == FTMSUUID.controlPointID, let cmd = ControlCommand(value) {
            log("zwift → trainer: \(describe(cmd))")
        }
        return .forward(value)
    }

    public func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict {
        if ch == FTMSUUID.controlPointID, let r = ControlResponse(value) {
            log(String(format: "trainer: result op 0x%02X → %d", r.requestOp, r.result))
        } else if ch == FTMSUUID.statusID, let op = value.first, op == 0x12 || op == 0xFF {
            log(op == 0xFF ? "trainer: control permission lost" : "trainer: simulation parameters changed")
        } else if verboseData, ch == FTMSUUID.indoorBikeDataID, let d = IndoorBikeData(value) {
            log(String(format: "data: %.2f km/h  %.1f rpm  %d W", d.speedKmh ?? 0, d.cadenceRpm ?? 0, d.powerW ?? 0))
        }
        return .forward(value)
    }
}

/// Scales the SIM grade, e.g. 0.5 = half the road's gradient.
public final class GradeScaleInterceptor: Interceptor {
    let factor: Double
    public init(factor: Double) { self.factor = factor }
    public func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict {
        guard ch == FTMSUUID.controlPointID, case .simulation(var p) = ControlCommand(value) else { return .forward(value) }
        p.gradeRaw = Int16(max(Double(Int16.min), min(Double(Int16.max), (Double(p.gradeRaw) * factor).rounded())))
        return .forward(ControlCommand.simulation(p).encoded())
    }
}

/// Caps ERG target power.
public final class ErgCapInterceptor: Interceptor {
    let maxW: Int16
    public init(maxW: Int16) { self.maxW = maxW }
    public func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict {
        guard ch == FTMSUUID.controlPointID, case .setTargetPower(let w) = ControlCommand(value), w > maxW else {
            return .forward(value)
        }
        return .forward(ControlCommand.setTargetPower(maxW).encoded())
    }
}

/// Adds a fixed offset to the power reported in Indoor Bike Data.
public final class PowerOffsetInterceptor: Interceptor {
    let offsetW: Int
    public init(offsetW: Int) { self.offsetW = offsetW }
    public func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict {
        guard ch == FTMSUUID.indoorBikeDataID, let at = IndoorBikeData.powerOffset(value) else { return .forward(value) }
        var b = [UInt8](value)
        let p = Int(Int16(bitPattern: UInt16(b[at]) | UInt16(b[at + 1]) << 8)) + offsetW
        let clamped = Int16(max(Int(Int16.min), min(Int(Int16.max), p)))
        let le = le16(clamped)
        b[at] = le[0]; b[at + 1] = le[1]
        return .forward(Data(b))
    }
}
