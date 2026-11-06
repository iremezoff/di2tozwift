import Foundation
import Testing
@testable import DirConCore

struct PhysicsTests {
    let ladder = defaultLadder()
    func k(_ gear: Int) -> Double { ladder.gears[gear - 1].k }

    @Test func transformReproducesPower() {
        let road = RoadState(windMS: 0, gradePct: 5, crr: 0.004, cw: 0.51)
        let vp = Physics.trainerSpeed(cadenceRpm: 90, ratio: 52.0 / 14.0, circumferenceMM: 2105)
        for gear in [1, 4, 12, 21, 24] {
            let kk = k(gear)
            let trainer = Physics.roadForce(speed: vp, road: Physics.transform(road, k: kk), massKg: 85) * vp
            let real = Physics.roadForce(speed: kk * vp, road: road, massKg: 85) * kk * vp
            #expect(abs(trainer - real) / real < 1e-9, "gear \(gear): \(trainer) vs \(real)")
        }
    }

    @Test func flatGear21Is450W() {
        let road = RoadState(windMS: 0, gradePct: 0, crr: 0.004, cw: 0.51)
        let v = Physics.trainerSpeed(cadenceRpm: 90, ratio: 52.0 / 14.0, circumferenceMM: 2105)
        let p = Physics.roadForce(speed: v, road: road, massKg: 85) * v
        #expect(abs(p - 450) <= 1, "\(p)")
    }

    @Test func steepGrade24ClampsTo25() {
        let road = RoadState(windMS: 0, gradePct: 20, crr: 0.004, cw: 0.51)
        #expect(abs(Physics.transform(road, k: k(24)).gradePct - 25.78) < 0.01)
        #expect(Physics.strategyB(road, k: k(24), maxGradePct: 25).gradeRaw == 2500)
    }

    @Test func cwRounding() {
        let road = RoadState(windMS: 0, gradePct: 0, crr: 0.004, cw: 0.51)
        #expect(Physics.strategyB(road, k: k(24), maxGradePct: 25).cwRaw == 105)
        #expect(Physics.strategyB(road, k: k(1), maxGradePct: 25).cwRaw == 1)
    }

    @Test func transformNegativeGrade() {
        let road = RoadState(windMS: 0, gradePct: -8, crr: 0.004, cw: 0.51)
        let theta = atan(-0.08)
        let expected = Int16((tan(asin(k(1) * sin(theta))) * 10000).rounded())
        let p = Physics.strategyB(road, k: k(1), maxGradePct: 25)
        #expect(p.gradeRaw == expected)
        #expect(p.gradeRaw < 0)
        let steep = RoadState(windMS: 0, gradePct: -40, crr: 0.004, cw: 0.51)
        #expect(Physics.strategyB(steep, k: k(24), maxGradePct: 25).gradeRaw == -2500)
    }

    @Test func transformZeroCw() {
        let road = RoadState(windMS: 0, gradePct: 3, crr: 0, cw: 0)
        let p = Physics.strategyB(road, k: k(1), maxGradePct: 25)
        #expect(p.cwRaw == 0)
        #expect(p.crrRaw == 0)
    }

    @Test func windScalesInverse() {
        let road = RoadState(windMS: 2, gradePct: 0, crr: 0.004, cw: 0.51)
        #expect(Physics.strategyB(road, k: 0.5, maxGradePct: 25).windRaw == 4000)
    }

    @Test func identityGearIsByteExact() {
        guard case .simulation(let zwift) = ControlCommand(hex("11 00 00 EE 00 28 33"))! else { Issue.record(); return }
        #expect(Physics.strategyB(RoadState(zwift), k: 1, maxGradePct: 25) == zwift)
        #expect(Physics.strategyB(RoadState(zwift), k: k(21), maxGradePct: 25) == zwift)
    }
}
