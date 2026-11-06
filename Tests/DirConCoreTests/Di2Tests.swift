import Foundation
import Testing
@testable import DirConCore

/// Builds a D-FLY packet: counter byte, then channels 1–4.
private func pkt(_ counter: UInt8, _ ch: [UInt8]) -> Data { Data([counter] + ch) }

private final class Rig {
    let sched = TestScheduler()
    let mapper: Di2ShiftMapper
    var shifts: [ShiftDirection] = []
    init() {
        mapper = Di2ShiftMapper(scheduler: sched, repeatInterval: 0.15)
        mapper.onShift = { [unowned self] in self.shifts.append($0) }
        mapper.receive(pkt(0x20, [0xF0, 0xF0, 0xF0, 0xF0]))  // baseline
    }
}

struct Di2Tests {
    @Test func firstPacketIsBaseline() {
        let r = Rig()
        #expect(r.shifts.isEmpty)
    }

    @Test func rightLeverShortPressShiftsUp() {
        let r = Rig()
        r.mapper.receive(pkt(0x21, [0xF0, 0xF0, 0x11, 0xF0]))  // Ch.3 short
        r.mapper.receive(pkt(0x22, [0xF0, 0xF0, 0x11, 0x12]))  // Ch.4 short
        #expect(r.shifts == [.up, .up])
    }

    @Test func leftLeverShortPressShiftsDown() {
        let r = Rig()
        r.mapper.receive(pkt(0x21, [0x11, 0xF0, 0xF0, 0xF0]))  // Ch.1
        r.mapper.receive(pkt(0x22, [0x11, 0x11, 0xF0, 0xF0]))  // Ch.2
        r.mapper.receive(pkt(0x23, [0x12, 0x11, 0xF0, 0xF0]))  // Ch.1 again (counter moved)
        #expect(r.shifts == [.down, .down, .down])
    }

    @Test func doublePressShiftsTwice() {
        let r = Rig()
        r.mapper.receive(pkt(0x21, [0xF0, 0xF0, 0xF0, 0x47]))
        #expect(r.shifts == [.up, .up])
    }

    @Test func longPressRepeatsUntilRelease() {
        let r = Rig()
        r.mapper.receive(pkt(0x21, [0x22, 0xF0, 0xF0, 0xF0]))  // long press start on Ch.1
        #expect(r.shifts == [.down])
        r.sched.advance(by: 0.46)                              // repeats at 0.15, 0.30, 0.45
        #expect(r.shifts.count == 4)
        r.mapper.receive(pkt(0x22, [0x33, 0xF0, 0xF0, 0xF0]))  // still held: no extra shift
        #expect(r.shifts.count == 4)
        r.sched.advance(by: 0.15)
        #expect(r.shifts.count == 5)
        r.mapper.receive(pkt(0x23, [0x04, 0xF0, 0xF0, 0xF0]))  // released
        r.sched.advance(by: 1)
        #expect(r.shifts.count == 5)
        #expect(Set(r.shifts) == [.down])
    }

    @Test func reconnectStartsFromNewBaseline() {
        let r = Rig()
        r.mapper.receive(pkt(0x21, [0x22, 0xF0, 0xF0, 0xF0]))  // long hold in progress
        r.mapper.reset()                                       // link dropped
        r.sched.advance(by: 1)
        #expect(r.shifts == [.down])                           // repeat stopped
        r.mapper.receive(pkt(0x20, [0xF0, 0xF0, 0x11, 0xF0]))  // first packet after reconnect
        #expect(r.shifts == [.down])
        r.mapper.receive(pkt(0x21, [0xF0, 0xF0, 0x12, 0xF0]))
        #expect(r.shifts == [.down, .up])
    }

    @Test func decodeEvents() {
        #expect(Di2Event(0xF0) == .idle)
        #expect(Di2Event(0x11) == .short)
        #expect(Di2Event(0x24) == .longStart)
        #expect(Di2Event(0x35) == .longHeld)
        #expect(Di2Event(0x06) == .released)
        #expect(Di2Event(0x47) == .double)
    }

    @Test func shortPacketIgnored() {
        let r = Rig()
        r.mapper.receive(Data([0x21]))
        r.mapper.receive(Data())
        #expect(r.shifts.isEmpty)
    }
}
