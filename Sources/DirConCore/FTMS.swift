import Foundation

public enum FTMSUUID {
    public static let service = BLEUUID(short: 0x1826)
    public static let feature = BLEUUID(short: 0x2ACC)
    public static let indoorBikeData = BLEUUID(short: 0x2AD2)
    public static let trainingStatus = BLEUUID(short: 0x2AD3)
    public static let resistanceRange = BLEUUID(short: 0x2AD6)
    public static let powerRange = BLEUUID(short: 0x2AD8)
    public static let controlPoint = BLEUUID(short: 0x2AD9)
    public static let status = BLEUUID(short: 0x2ADA)

    public static let controlPointID = CharacteristicID(service: service, characteristic: controlPoint)
    public static let featureID = CharacteristicID(service: service, characteristic: feature)
    public static let indoorBikeDataID = CharacteristicID(service: service, characteristic: indoorBikeData)
    public static let statusID = CharacteristicID(service: service, characteristic: status)
}

// MARK: little-endian helpers

extension Data {
    func u16(_ at: Int) -> UInt16 {
        let b = [UInt8](self)
        return UInt16(b[at]) | UInt16(b[at + 1]) << 8
    }
    func i16(_ at: Int) -> Int16 { Int16(bitPattern: u16(at)) }
}

func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func le16(_ v: Int16) -> [UInt8] { le16(UInt16(bitPattern: v)) }

/// Op 0x11 parameters in their FTMS field units.
public struct SimParams: Equatable {
    public var windRaw: Int16   // 0.001 m/s
    public var gradeRaw: Int16  // 0.01 %
    public var crrRaw: UInt8    // 0.0001
    public var cwRaw: UInt8     // 0.01 kg/m

    public init(windRaw: Int16, gradeRaw: Int16, crrRaw: UInt8, cwRaw: UInt8) {
        self.windRaw = windRaw
        self.gradeRaw = gradeRaw
        self.crrRaw = crrRaw
        self.cwRaw = cwRaw
    }

    public var windMS: Double { Double(windRaw) / 1000 }
    public var gradePct: Double { Double(gradeRaw) / 100 }
    public var crr: Double { Double(crrRaw) / 10000 }
    public var cw: Double { Double(cwRaw) / 100 }
}

public enum ControlCommand: Equatable {
    case requestControl
    case reset
    case setTargetResistance(UInt8)
    case setTargetPower(Int16)
    case startResume
    case stopPause(UInt8)
    case simulation(SimParams)
    case wheelCircumference(UInt16)  // 0.1 mm
    case other(op: UInt8, params: Data)

    /// nil only for empty data; known op codes with the wrong length decode as `.other`.
    public init?(_ data: Data) {
        guard let op = data.first else { return nil }
        let p = Data(data.dropFirst())
        switch (op, p.count) {
        case (0x00, 0): self = .requestControl
        case (0x01, 0): self = .reset
        case (0x04, 1): self = .setTargetResistance(p[p.startIndex])
        case (0x05, 2): self = .setTargetPower(p.i16(0))
        case (0x07, 0): self = .startResume
        case (0x08, 1): self = .stopPause(p[p.startIndex])
        case (0x11, 6):
            let b = [UInt8](p)
            self = .simulation(SimParams(windRaw: p.i16(0), gradeRaw: p.i16(2), crrRaw: b[4], cwRaw: b[5]))
        case (0x12, 2): self = .wheelCircumference(p.u16(0))
        default: self = .other(op: op, params: p)
        }
    }

    public var opCode: UInt8 {
        switch self {
        case .requestControl: return 0x00
        case .reset: return 0x01
        case .setTargetResistance: return 0x04
        case .setTargetPower: return 0x05
        case .startResume: return 0x07
        case .stopPause: return 0x08
        case .simulation: return 0x11
        case .wheelCircumference: return 0x12
        case .other(let op, _): return op
        }
    }

    public func encoded() -> Data {
        var out: [UInt8] = [opCode]
        switch self {
        case .requestControl, .reset, .startResume: break
        case .setTargetResistance(let v), .stopPause(let v): out.append(v)
        case .setTargetPower(let w): out += le16(w)
        case .simulation(let s): out += le16(s.windRaw) + le16(s.gradeRaw) + [s.crrRaw, s.cwRaw]
        case .wheelCircumference(let c): out += le16(c)
        case .other(_, let params): out += params
        }
        return Data(out)
    }
}

/// Control Point indication: 0x80, request op code, result.
public struct ControlResponse: Equatable {
    public static let success: UInt8 = 1
    public static let notSupported: UInt8 = 2
    public static let invalidParameter: UInt8 = 3
    public static let failed: UInt8 = 4
    public static let notPermitted: UInt8 = 5

    public let requestOp: UInt8
    public let result: UInt8

    public init(requestOp: UInt8, result: UInt8) {
        self.requestOp = requestOp
        self.result = result
    }

    public init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == 0x80 else { return nil }
        self.init(requestOp: b[1], result: b[2])
    }

    public func encoded() -> Data { Data([0x80, requestOp, result]) }
}

/// Indoor Bike Data (0x2AD2): flags, then flagged fields. Trailing bytes are ignored.
public struct IndoorBikeData: Equatable {
    public var speedKmh: Double?
    public var cadenceRpm: Double?
    public var powerW: Int?
    public var heartRate: Int?

    public init?(_ data: Data) {
        let d = Data(data)
        guard d.count >= 2 else { return nil }
        let flags = d.u16(0)
        var o = 2
        func need(_ n: Int) -> Bool { o + n <= d.count }
        if flags & 0x0001 == 0 { guard need(2) else { return nil }; speedKmh = Double(d.u16(o)) / 100; o += 2 }
        if flags & 0x0002 != 0 { guard need(2) else { return nil }; o += 2 }
        if flags & 0x0004 != 0 { guard need(2) else { return nil }; cadenceRpm = Double(d.u16(o)) / 2; o += 2 }
        if flags & 0x0008 != 0 { guard need(2) else { return nil }; o += 2 }
        if flags & 0x0010 != 0 { guard need(3) else { return nil }; o += 3 }
        if flags & 0x0020 != 0 { guard need(2) else { return nil }; o += 2 }
        if flags & 0x0040 != 0 { guard need(2) else { return nil }; powerW = Int(d.i16(o)); o += 2 }
        if flags & 0x0080 != 0 { guard need(2) else { return nil }; o += 2 }
        if flags & 0x0100 != 0 { guard need(5) else { return nil }; o += 5 }
        if flags & 0x0200 != 0 { guard need(1) else { return nil }; heartRate = Int([UInt8](d)[o]); o += 1 }
    }
}

extension IndoorBikeData {
    /// Byte offset of the Instantaneous Power field, nil when absent or cut off.
    public static func powerOffset(_ data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        let flags = Data(data).u16(0)
        guard flags & 0x0040 != 0 else { return nil }
        var o = 2
        if flags & 0x0001 == 0 { o += 2 }
        if flags & 0x0002 != 0 { o += 2 }
        if flags & 0x0004 != 0 { o += 2 }
        if flags & 0x0008 != 0 { o += 2 }
        if flags & 0x0010 != 0 { o += 3 }
        if flags & 0x0020 != 0 { o += 2 }
        return o + 2 <= data.count ? o : nil
    }
}

public enum FeatureBits {
    /// Target Setting features (second uint32).
    public static func targetSettings(_ v: Data) -> UInt32 {
        let b = [UInt8](v)
        guard b.count >= 8 else { return 0 }
        return UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
    }

    /// The trainer's value with target bits 13 (simulation) and 3 (power) set and 14 (circumference) cleared.
    public static func forZwift(_ trainer: Data) -> Data {
        var b = [UInt8](trainer)
        while b.count < 8 { b.append(0) }
        let t = (targetSettings(Data(b)) | (1 << 13) | (1 << 3)) & ~UInt32(1 << 14)
        b[4] = UInt8(t & 0xFF); b[5] = UInt8((t >> 8) & 0xFF); b[6] = UInt8((t >> 16) & 0xFF); b[7] = UInt8(t >> 24)
        return Data(b)
    }
}

public func describe(_ cmd: ControlCommand) -> String {
    switch cmd {
    case .requestControl: return "Request Control"
    case .reset: return "Reset"
    case .setTargetResistance(let r): return "Set Target Resistance \(Double(r) / 10)"
    case .setTargetPower(let w): return "ERG \(w) W"
    case .startResume: return "Start/Resume"
    case .stopPause(let v): return "Stop/Pause \(v)"
    case .simulation(let s):
        return String(format: "SIM wind %.3f m/s grade %.2f%% Crr %.4f Cw %.2f", s.windMS, s.gradePct, s.crr, s.cw)
    case .wheelCircumference(let c): return String(format: "Wheel circumference %.1f mm", Double(c) / 10)
    case .other(let op, let p): return String(format: "op 0x%02X ", op) + p.map { String(format: "%02x", $0) }.joined()
    }
}
