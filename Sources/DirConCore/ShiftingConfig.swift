import Foundation

public enum GearStart: Codable, Equatable {
    case identity
    case number(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self = .number(n)
        } else if try c.decode(String.self) == "identity" {
            self = .identity
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "start must be \"identity\" or a gear number")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .identity: try c.encode("identity")
        case .number(let n): try c.encode(n)
        }
    }
}

public enum StrategySetting: String, Codable {
    case auto, circumference, transform
}

/// The shifting spec's configuration keys (snake_case in JSON); missing keys take the spec's defaults.
public struct ShiftingConfig: Codable, Equatable {
    public var enabled = true
    public var physicalRing = 52
    public var physicalCog = 14
    public var rings = [52, 36]
    public var cogs = [11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30, 34]
    public var wheelCircumferenceMM = 2105.0
    public var minStepPct = 0.0
    public var start = GearStart.identity
    public var strategy = StrategySetting.auto
    public var maxGradePct = 25.0
    public var repeatIntervalMS = 150

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled
        case physicalRing = "physical_ring"
        case physicalCog = "physical_cog"
        case rings, cogs
        case wheelCircumferenceMM = "wheel_circumference_mm"
        case minStepPct = "min_step_pct"
        case start, strategy
        case maxGradePct = "max_grade_pct"
        case repeatIntervalMS = "repeat_interval_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShiftingConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        physicalRing = try c.decodeIfPresent(Int.self, forKey: .physicalRing) ?? d.physicalRing
        physicalCog = try c.decodeIfPresent(Int.self, forKey: .physicalCog) ?? d.physicalCog
        rings = try c.decodeIfPresent([Int].self, forKey: .rings) ?? d.rings
        cogs = try c.decodeIfPresent([Int].self, forKey: .cogs) ?? d.cogs
        wheelCircumferenceMM = try c.decodeIfPresent(Double.self, forKey: .wheelCircumferenceMM) ?? d.wheelCircumferenceMM
        minStepPct = try c.decodeIfPresent(Double.self, forKey: .minStepPct) ?? d.minStepPct
        start = try c.decodeIfPresent(GearStart.self, forKey: .start) ?? d.start
        strategy = try c.decodeIfPresent(StrategySetting.self, forKey: .strategy) ?? d.strategy
        maxGradePct = try c.decodeIfPresent(Double.self, forKey: .maxGradePct) ?? d.maxGradePct
        repeatIntervalMS = try c.decodeIfPresent(Int.self, forKey: .repeatIntervalMS) ?? d.repeatIntervalMS
    }

    public var ladder: GearLadder {
        GearLadder(rings: rings, cogs: cogs, physicalRing: physicalRing, physicalCog: physicalCog, minStepPct: minStepPct)
    }
}
