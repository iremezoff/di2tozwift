import Foundation
import Testing
@testable import DirConCore

/// Zwift client 1 with control and a SIM frame already sent.
private func rig(_ configure: (SimulatedTrainer) -> Void = { _ in }, sim: Bool = true)
    -> (Harness, VirtualShifting, () -> [String]) {
    var statuses: [String] = []
    let vs = VirtualShifting(config: ShiftingConfig(), status: { statuses.append($0) }, log: { _ in })
    let h = Harness(interceptors: [vs])
    configure(h.trainer)
    h.connect(1)
    h.write(1, 0x2AD9, "00", seq: 1)
    if sim { h.write(1, 0x2AD9, zwiftSim, seq: 2) }
    h.sched.advance(by: 0.1)
    _ = h.take(1)
    return (h, vs, { statuses })
}

let zwiftSim = "11 00 00 EE 00 28 33"
let zwiftRoad = RoadState(windMS: 0, gradePct: 2.38, crr: 0.004, cw: 0.51)

struct VirtualShiftingTests {
    @Test func requestControlAnsweredLocally() {
        let vs = VirtualShifting(config: ShiftingConfig(), status: { _ in }, log: { _ in })
        let h = Harness(interceptors: [vs])
        h.connect(1)
        h.write(1, 0x2AD9, "00", seq: 1)
        let f = h.take(1)
        #expect(f.first?.code == 0)
        #expect(Harness.notifications(f, 0x2AD9) == [hex("80 00 01")])
        #expect(h.cpWrites() == [hex("00")])  // only the proxy's own, at ready
        #expect(vs.strategy == .transform)
    }

    @Test func gear21IsTransparent() {
        let (h, vs, _) = rig()
        #expect(vs.gear.number == 21)
        #expect(h.cpWrites().last == hex(zwiftSim))
    }

    @Test func zwiftSimAnsweredLocally() {
        let vs = VirtualShifting(config: ShiftingConfig(), status: { _ in }, log: { _ in })
        let h = Harness(interceptors: [vs])
        h.connect(1)
        h.write(1, 0x2AD9, "00", seq: 1)
        _ = h.take(1)
        h.write(1, 0x2AD9, zwiftSim, seq: 2)
        let f = h.take(1)
        #expect(f.first?.type == MessageType.writeCharacteristic.rawValue)
        #expect(Harness.notifications(f, 0x2AD9) == [hex("80 11 01")])
    }

    @Test func shiftDownSendsTransformed() {
        let (h, vs, statuses) = rig()
        for _ in 0..<7 { vs.shift(.down); h.sched.advance(by: 0.05) }
        #expect(vs.gear.number == 14)
        #expect(statuses().last == "gear 14/24  36×14  k=0.692")
        let expected = ControlCommand.simulation(Physics.strategyB(zwiftRoad, k: vs.gear.k, maxGradePct: 25)).encoded()
        #expect(h.cpWrites().last == expected)
    }

    @Test func burstCollapses() {
        let (h, vs, _) = rig()
        let mark = h.cpWrites().count
        for _ in 0..<10 { vs.shift(.up) }  // all before any indication
        h.sched.advance(by: 0.5)
        #expect(vs.gear.number == 24)
        let after = Array(h.cpWrites().dropFirst(mark))
        #expect(!after.isEmpty && after.count <= 2)
        let k24 = vs.gear.k
        #expect(after.last == ControlCommand.simulation(Physics.strategyB(zwiftRoad, k: k24, maxGradePct: 25)).encoded())
        #expect(Harness.notifications(h.take(1), 0x2AD9).isEmpty)
    }

    @Test func shiftAtEndIsDropped() {
        let (h, vs, _) = rig()
        for _ in 0..<3 { vs.shift(.up); h.sched.advance(by: 0.05) }
        let mark = h.cpWrites().count
        vs.shift(.up)
        h.sched.advance(by: 0.05)
        #expect(vs.gear.number == 24)
        #expect(h.cpWrites().count == mark)
    }

    @Test func ergIgnoresGears() {
        let (h, vs, _) = rig()
        h.write(1, 0x2AD9, "05 96 00", seq: 3)
        #expect(h.cpWrites().last == hex("05 96 00"))
        let mark = h.cpWrites().count
        vs.shift(.down); vs.shift(.down)
        h.sched.advance(by: 0.5)
        #expect(h.cpWrites().count == mark)
        #expect(vs.gear.number == 19)
        h.write(1, 0x2AD9, zwiftSim, seq: 4)
        h.sched.advance(by: 0.1)
        #expect(h.cpWrites().last == ControlCommand.simulation(Physics.strategyB(zwiftRoad, k: vs.gear.k, maxGradePct: 25)).encoded())
    }

    @Test func ownWriteRejectedIsSwallowed() {
        let (h, vs, _) = rig { t in
            t.respond = { $0.opCode == 0x11 ? ControlResponse.failed : ControlResponse.success }
        }
        _ = h.take(1)
        vs.shift(.down)
        h.sched.advance(by: 0.1)
        #expect(Harness.notifications(h.take(1), 0x2AD9).isEmpty)
        #expect(vs.gear.number == 20)
        let mark = h.cpWrites().count
        h.write(1, 0x2AD9, "11 00 00 F4 01 28 33", seq: 5)
        h.sched.advance(by: 0.1)
        #expect(h.cpWrites().count == mark + 1)
    }

    @Test func noIndicationRetriesOnceThenDegraded() {
        let (h, vs, statuses) = rig()
        h.trainer.respond = { _ in nil }
        let mark = h.cpWrites().count
        vs.shift(.down)
        h.sched.advance(by: 0.5)
        #expect(h.cpWrites().count == mark + 1)
        h.sched.advance(by: 1.0)
        #expect(h.cpWrites().count == mark + 2)
        #expect(h.cpWrites().last == h.cpWrites()[mark])
        h.sched.advance(by: 1.0)
        #expect(statuses().contains("trainer link degraded"))
        #expect(vs.gear.number == 20)
    }

    @Test func featureReadRewritten() {
        let vs = VirtualShifting(config: ShiftingConfig(), status: { _ in }, log: { _ in })
        let h = Harness(interceptors: [vs])
        h.trainer.feature = hex("00 00 00 00 00 60 00 00")
        h.connect(1)
        h.send(1, .readCharacteristic, seq: 1, BLEUUID(short: 0x2ACC).data)
        #expect(h.take(1)[0].data.dropFirst(16) == hex("00 00 00 00 08 20 00 00"))
    }

    @Test func wheelCircumferenceOwned() {
        let (h, vs, _) = rig()
        let mark = h.cpWrites().count
        h.write(1, 0x2AD9, "12 3A 52", seq: 3)
        #expect(Harness.notifications(h.take(1), 0x2AD9) == [hex("80 12 01")])
        #expect(h.cpWrites().count == mark)
        #expect(vs.baseCircumferenceMM == 2105.0)
    }

    @Test func gearSurvivesClientReconnect() {
        let (h, vs, _) = rig()
        vs.shift(.down)
        h.sched.advance(by: 0.1)
        h.core.clientDisconnected(1)
        h.connect(2)
        h.write(2, 0x2AD9, "00", seq: 1)
        #expect(Harness.notifications(h.take(2), 0x2AD9) == [hex("80 00 01")])
        #expect(vs.gear.number == 20)
    }

    @Test func reconnectReappliesGear() {
        let (h, vs, _) = rig()
        vs.shift(.down)
        h.sched.advance(by: 0.1)
        h.trainer.simulateDisconnect()
        h.sched.advance(by: 0.1)
        let mark = h.cpWrites().count
        h.trainer.simulateReconnect()
        h.sched.advance(by: 0.5)
        let expected = ControlCommand.simulation(Physics.strategyB(zwiftRoad, k: vs.gear.k, maxGradePct: 25)).encoded()
        #expect(Array(h.cpWrites().dropFirst(mark)) == [hex("00"), expected])
    }

    @Test func statusOnlyFromOwnWritesDropped() {
        let (h, vs, _) = rig()
        h.enable(1, 0x2ADA, true, seq: 9)
        _ = h.take(1)
        h.sched.advance(by: 2)
        h.core.trainerValue(hex("12 00 00 EE 00 28 33"), for: FTMSUUID.statusID)
        #expect(Harness.notifications(h.take(1), 0x2ADA).count == 1)
        vs.shift(.down)
        h.sched.advance(by: 0.2)
        h.core.trainerValue(hex("12 00 00 E0 00 28 33"), for: FTMSUUID.statusID)
        #expect(Harness.notifications(h.take(1), 0x2ADA).isEmpty)
    }

    @Test func circumferenceStrategyWhenSupported() {
        var statuses: [String] = []
        let vs = VirtualShifting(config: ShiftingConfig(), status: { statuses.append($0) }, log: { _ in })
        let sched = TestScheduler()
        let trainer = SimulatedTrainer(scheduler: sched)
        trainer.feature = hex("00 00 00 00 08 60 00 00")
        trainer.respond = { _ in ControlResponse.success }
        let core = ProxyCore(trainer: trainer, interceptors: [vs], scheduler: sched, status: { _ in }, log: { _ in })
        _ = core.clientConnected(1) { _ in }
        trainer.start()
        sched.advance(by: 0.5)
        #expect(vs.strategy == .circumference)
        core.receive(Frame(type: 4, seq: 1, code: 0, data: BLEUUID(short: 0x2AD9).data + hex(zwiftSim)).encoded(), from: 1)
        sched.advance(by: 0.1)
        vs.shift(.down)
        sched.advance(by: 0.1)
        let cp = trainer.writes.filter { $0.0 == FTMSUUID.controlPointID }.map(\.1)
        #expect(cp.contains(hex(zwiftSim)))
        let l = UInt16((2105 * vs.gear.k * 10).rounded())
        #expect(cp.last == ControlCommand.wheelCircumference(l).encoded())
    }
}
