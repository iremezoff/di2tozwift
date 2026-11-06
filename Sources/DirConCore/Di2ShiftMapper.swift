import Foundation

/// One D-FLY channel byte: high nibble = event, low nibble = per-channel press counter.
/// Observed on an RD-R8150 (Ultegra Di2 12-speed).
public enum Di2Event: Equatable {
    case idle, short, double, longStart, longHeld, released

    public init(_ v: UInt8) {
        if v == 0xF0 { self = .idle }
        else if v & 0x40 != 0 { self = .double }
        else if v & 0x20 != 0 { self = v & 0x10 != 0 ? .longHeld : .longStart }
        else if v & 0x10 != 0 { self = .short }
        else { self = .released }
    }
}

/// Turns D-FLY packets into shifts. Ch.1 and Ch.2 (left lever) shift down (easier); Ch.3 and Ch.4
/// (right lever) shift up (harder). Short = one shift, double = two, long = one shift then repeats
/// every `repeatInterval` until release. Call on the core queue.
public final class Di2ShiftMapper {
    public var onShift: ((ShiftDirection) -> Void)?

    private let scheduler: Scheduler
    private let repeatInterval: Double
    private var last: [UInt8]?
    private var repeating: [Int: Cancellable] = [:]

    public init(scheduler: Scheduler, repeatInterval: Double) {
        self.scheduler = scheduler
        self.repeatInterval = repeatInterval
    }

    public static func direction(channel: Int) -> ShiftDirection? {
        switch channel {
        case 1, 2: return .down
        case 3, 4: return .up
        default: return nil
        }
    }

    /// The link dropped: stop any repeat; the next packet is a fresh baseline.
    public func reset() {
        for (_, c) in repeating { c.cancel() }
        repeating = [:]
        last = nil
    }

    public func receive(_ packet: Data) {
        let bytes = [UInt8](packet)
        guard bytes.count >= 2 else { return }
        let channels = Array(bytes.dropFirst())  // byte 0 is a message counter
        guard let previous = last, previous.count == channels.count else {
            last = channels
            return
        }
        last = channels
        for (i, (old, new)) in zip(previous, channels).enumerated() where old != new {
            let ch = i + 1
            guard let dir = Self.direction(channel: ch) else { continue }
            switch Di2Event(new) {
            case .short:
                onShift?(dir)
            case .double:
                onShift?(dir)
                onShift?(dir)
            case .longStart:
                onShift?(dir)
                startRepeat(ch, dir)
            case .longHeld:
                if repeating[ch] == nil { startRepeat(ch, dir) }
            case .released, .idle:
                repeating.removeValue(forKey: ch)?.cancel()
            }
        }
    }

    private func startRepeat(_ ch: Int, _ dir: ShiftDirection) {
        repeating[ch]?.cancel()
        repeating[ch] = scheduler.after(repeatInterval) { [weak self] in
            guard let self, self.repeating[ch] != nil else { return }
            self.onShift?(dir)
            self.startRepeat(ch, dir)
        }
    }
}
