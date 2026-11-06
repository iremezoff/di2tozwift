import Foundation

/// Road state as Zwift sends it in op 0x11, in SI units (Cw in kg/m, aero force ½·Cw·v²).
public struct RoadState: Equatable {
    public var windMS: Double
    public var gradePct: Double
    public var crr: Double
    public var cw: Double

    public init(windMS: Double, gradePct: Double, crr: Double, cw: Double) {
        self.windMS = windMS
        self.gradePct = gradePct
        self.crr = crr
        self.cw = cw
    }

    public init(_ p: SimParams) {
        self.init(windMS: p.windMS, gradePct: p.gradePct, crr: p.crr, cw: p.cw)
    }
}

public enum Physics {
    public static let g = 9.81

    /// F_road(u) = m g (sin θ + Crr cos θ) + ½ Cw (u + w)²
    public static func roadForce(speed u: Double, road: RoadState, massKg: Double) -> Double {
        let theta = atan(road.gradePct / 100)
        let air = u + road.windMS
        return massKg * g * (sin(theta) + road.crr * cos(theta)) + 0.5 * road.cw * air * air
    }

    /// Exact, unrounded parameter set that makes a standard trainer model produce gear k's force.
    public static func transform(_ r: RoadState, k: Double) -> RoadState {
        let theta = atan(r.gradePct / 100)
        let sinT = max(-1, min(1, k * sin(theta)))
        let thetaP = asin(sinT)
        return RoadState(
            windMS: r.windMS / k,
            gradePct: tan(thetaP) * 100,
            crr: k * r.crr * cos(theta) / cos(thetaP),
            cw: k * k * k * r.cw
        )
    }

    /// Strategy B: transform, then round and clamp to the 0x11 field ranges.
    public static func strategyB(_ r: RoadState, k: Double, maxGradePct: Double) -> SimParams {
        let t = transform(r, k: k)
        let grade = (t.gradePct * 100).rounded()
        let gradeLimit = (maxGradePct * 100).rounded()
        let crr = (t.crr * 10000).rounded()
        let cw = (t.cw * 100).rounded()
        let wind = (t.windMS * 1000).rounded()
        return SimParams(
            windRaw: Int16(max(Double(Int16.min), min(Double(Int16.max), wind))),
            gradeRaw: Int16(max(-gradeLimit, min(gradeLimit, grade))),
            crrRaw: UInt8(max(0, min(255, crr))),
            cwRaw: r.cw > 0 ? UInt8(max(1, min(255, cw))) : 0
        )
    }

    /// Trainer (physical) speed in m/s.
    public static func trainerSpeed(cadenceRpm: Double, ratio: Double, circumferenceMM: Double) -> Double {
        cadenceRpm / 60 * ratio * circumferenceMM / 1000
    }
}
