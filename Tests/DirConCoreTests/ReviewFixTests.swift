import Foundation
import Testing
@testable import DirConCore

struct ReviewFixTests {
    /// Finding 1: a bit-14 trainer that never answers the 0x12 probe must fall back to the transform.
    @Test func probeTimeoutFallsBackToTransform() {
        let vs = VirtualShifting(config: ShiftingConfig(), status: { _ in }, log: { _ in })
        let sched = TestScheduler()
        let trainer = SimulatedTrainer(scheduler: sched)
        trainer.feature = hex("00 00 00 00 08 60 00 00")
        trainer.respond = { cmd -> UInt8? in cmd.opCode == 0x12 ? nil : ControlResponse.success }
        let core = ProxyCore(trainer: trainer, interceptors: [vs], scheduler: sched, status: { _ in }, log: { _ in })
        _ = core.clientConnected(1) { _ in }
        trainer.start()
        sched.advance(by: 3)
        #expect(vs.strategy == .transform)
        core.receive(Frame(type: 4, seq: 1, code: 0, data: BLEUUID(short: 0x2AD9).data + hex(zwiftSim)).encoded(), from: 1)
        sched.advance(by: 0.1)
        #expect(trainer.writes.last.map(\.1) == hex(zwiftSim))
    }

    /// Finding 3: a replay that never gets its result must not eat Zwift's later result.
    @Test func swallowCountersResetOnReconnect() {
        let h = Harness()
        h.connect(1)
        h.write(1, 0x2AD9, "00", seq: 1)
        h.write(1, 0x2AD9, "05 96 00", seq: 2)
        _ = h.take(1)
        h.trainer.simulateDisconnect()
        h.sched.advance(by: 0.05)
        h.trainer.simulateReconnect()        // replays 00 and 05 ...
        h.trainer.simulateDisconnect()       // ... and drops before their results arrive
        h.sched.advance(by: 0.05)
        h.trainer.simulateReconnect()
        h.sched.advance(by: 0.5)
        _ = h.take(1)
        h.write(1, 0x2AD9, "05 C8 00", seq: 3)
        #expect(Harness.notifications(h.take(1), 0x2AD9) == [hex("80 05 01")])
    }

    /// Minor upgraded: after ERG → SIM, a reconnect must not replay the old ERG target.
    @Test func noStaleErgReplayAfterSim() {
        let vs = VirtualShifting(config: ShiftingConfig(), status: { _ in }, log: { _ in })
        let h = Harness(interceptors: [vs])
        h.connect(1)
        h.write(1, 0x2AD9, "00", seq: 1)
        h.write(1, 0x2AD9, "05 96 00", seq: 2)
        h.write(1, 0x2AD9, zwiftSim, seq: 3)
        h.sched.advance(by: 0.1)
        h.trainer.simulateDisconnect()
        h.sched.advance(by: 0.05)
        let mark = h.cpWrites().count
        h.trainer.simulateReconnect()
        h.sched.advance(by: 0.5)
        let after = Array(h.cpWrites().dropFirst(mark))
        #expect(!after.contains(hex("05 96 00")))
        #expect(after.last == hex(zwiftSim))
    }

    /// Finding 5: the network coming back with the same IPv4 still re-joins and re-announces.
    @Test func pathReturnWithSameAddressReannounces() {
        let ip: [UInt8] = [192, 168, 1, 20]
        #expect(MDNSResponder.shouldReannounce(previous: ip, current: ip) == false)
        #expect(MDNSResponder.shouldReannounce(previous: nil, current: ip) == true)
        #expect(MDNSResponder.shouldReannounce(previous: ip, current: [10, 0, 0, 2]) == true)
        #expect(MDNSResponder.shouldReannounce(previous: ip, current: nil) == false)
    }
}
