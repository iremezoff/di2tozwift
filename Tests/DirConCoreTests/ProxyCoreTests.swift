import Foundation
import Testing
@testable import DirConCore

struct ProxyCoreTests {
    @Test func discoverServicesListsAllowedOnly() {
        let h = Harness()
        h.connect(1)
        h.send(1, .discoverServices, seq: 1)
        let f = h.take(1)
        #expect(f.count == 1)
        #expect(f[0].code == 0 && f[0].seq == 1)
        #expect(f[0].data == Data([0x180A, 0x1826, 0x1818, 0x1816].flatMap { BLEUUID(short: $0).bytes }))
    }

    @Test func discoverCharacteristicsListsProps() {
        let h = Harness()
        h.connect(1)
        h.send(1, .discoverCharacteristics, seq: 2, BLEUUID(short: 0x1826).data)
        let f = h.take(1)[0]
        #expect(f.code == 0)
        #expect(f.data.prefix(16) == BLEUUID(short: 0x1826).data)
        #expect(f.data.count == 16 + 7 * 17)
        #expect(Array(f.data[16..<33]) == BLEUUID(short: 0x2AD9).bytes + [0x06])
    }

    @Test func discoverCharacteristicsHiddenServiceIs3() {
        let h = Harness()
        h.connect(1)
        h.send(1, .discoverCharacteristics, seq: 2, T600Profile.vendorService.data)
        let f = h.take(1)[0]
        #expect(f.code == ResponseCode.serviceNotFound.rawValue)
        #expect(f.data.isEmpty)
    }

    @Test func unknownTypeIs1() {
        let h = Harness()
        h.connect(1)
        h.core.receive(Frame(type: 9, seq: 3, code: 0, data: Data()).encoded(), from: 1)
        h.sched.advance(by: 0.05)
        #expect(h.take(1).map(\.code) == [ResponseCode.invalidMessageType.rawValue])
    }

    @Test func readUnknownCharIs4() {
        let h = Harness()
        h.connect(1)
        h.send(1, .readCharacteristic, seq: 4, BLEUUID(string: "8ce5cc04-0a4d-11e9-ab14-d663bd873d93")!.data)
        #expect(h.take(1).map(\.code) == [ResponseCode.characteristicNotFound.rawValue])
    }

    @Test func writeReadOnlyIs5() {
        let h = Harness()
        h.connect(1)
        h.write(1, 0x2ACC, "00", seq: 5)
        #expect(h.take(1).map(\.code) == [ResponseCode.operationNotSupported.rawValue])
        #expect(h.trainer.writes.isEmpty)
    }

    @Test func readStaticUsesCache() {
        let h = Harness()
        h.connect(1)
        h.send(1, .readCharacteristic, seq: 6, BLEUUID(short: 0x2ACC).data)
        let f = h.take(1)[0]
        #expect(f.code == 0)
        #expect(f.data == BLEUUID(short: 0x2ACC).data + T600Profile.feature)
        #expect(h.trainer.reads.isEmpty)
    }

    @Test func writeAnsweredAfterBLE() {
        let h = Harness()
        h.connect(1)
        h.write(1, 0x2AD9, "00", seq: 7)
        let f = h.take(1)
        #expect(f.count == 2)
        #expect(f[0].type == MessageType.writeCharacteristic.rawValue && f[0].seq == 7 && f[0].code == 0)
        #expect(f[0].data == BLEUUID(short: 0x2AD9).data)
        #expect(Harness.notifications(f, 0x2AD9) == [hex("80 00 01")])
        #expect(h.statuses.contains("control granted"))
    }

    @Test func subscriptionRefCount() {
        let h = Harness()
        h.connect(1)
        h.connect(2)
        h.enable(1, 0x2AD2, true, seq: 1)
        h.enable(2, 0x2AD2, true, seq: 1)
        #expect(h.trainer.notifyCalls.filter { $0.0 == FTMSUUID.indoorBikeDataID }.map(\.1) == [true])
        h.sched.advance(by: 1)
        #expect(Harness.notifications(h.take(1), 0x2AD2).count >= 3)
        #expect(Harness.notifications(h.take(2), 0x2AD2).count >= 3)
        h.enable(1, 0x2AD2, false, seq: 2)
        #expect(h.trainer.notifyCalls.filter { $0.0 == FTMSUUID.indoorBikeDataID }.map(\.1) == [true])
        h.core.clientDisconnected(2)
        #expect(h.trainer.notifyCalls.filter { $0.0 == FTMSUUID.indoorBikeDataID }.map(\.1) == [true, false])
    }

    @Test func secondClientNotPermitted() {
        let h = Harness()
        h.connect(1)
        h.connect(2)
        h.write(1, 0x2AD9, "00", seq: 1)
        let before = h.trainer.writes.count
        h.write(2, 0x2AD9, "05 96 00", seq: 1)
        let f = h.take(2)
        #expect(f.first?.code == 0)
        #expect(Harness.notifications(f, 0x2AD9) == [hex("80 05 05")])
        #expect(h.trainer.writes.count == before)
    }

    @Test func ownerDisconnectReleasesControl() {
        let h = Harness()
        h.connect(1)
        h.connect(2)
        h.write(1, 0x2AD9, "00", seq: 1)
        h.core.clientDisconnected(1)
        h.write(2, 0x2AD9, "00", seq: 1)
        #expect(Harness.notifications(h.take(2), 0x2AD9) == [hex("80 00 01")])
    }

    @Test func reconnectingQueuesNewestPerOp() {
        let h = Harness()
        h.connect(1)
        h.write(1, 0x2AD9, "00", seq: 1)
        _ = h.take(1)
        h.trainer.simulateDisconnect()
        h.sched.advance(by: 0.05)
        h.write(1, 0x2AD9, "05 64 00", seq: 2)
        h.write(1, 0x2AD9, "05 96 00", seq: 3)
        #expect(h.take(1).map(\.code) == [0, 0])
        let mark = h.trainer.writes.count
        h.trainer.simulateReconnect()
        h.sched.advance(by: 0.5)
        #expect(h.trainer.writes.dropFirst(mark).map(\.1) == [hex("00"), hex("05 96 00")])
        #expect(Harness.notifications(h.take(1), 0x2AD9) == [hex("80 05 01")])
    }

    @Test func reconnectReplaysLastControlAndRestoresSubscriptions() {
        let h = Harness()
        h.connect(1)
        h.enable(1, 0x2AD2, true, seq: 1)
        h.write(1, 0x2AD9, "00", seq: 2)
        h.write(1, 0x2AD9, "11 00 00 EE 00 28 33", seq: 3)
        _ = h.take(1)
        h.trainer.simulateDisconnect()
        h.sched.advance(by: 0.05)
        let mark = h.trainer.writes.count
        h.trainer.simulateReconnect()
        h.sched.advance(by: 0.5)
        #expect(h.trainer.writes.dropFirst(mark).map(\.1) == [hex("00"), hex("11 00 00 EE 00 28 33")])
        #expect(h.trainer.notifyCalls.last.map { [$0.0 == FTMSUUID.indoorBikeDataID, $0.1] } == [true, true])
        #expect(Harness.notifications(h.take(1), 0x2AD9).isEmpty)  // replay results swallowed
    }

    @Test func writeDuringReconnectNonControlIs2() {
        let h = Harness()
        h.connect(1)
        h.trainer.simulateDisconnect()
        h.sched.advance(by: 0.05)
        h.write(1, 0x2A55, "01", seq: 1)
        #expect(h.take(1).map(\.code) == [ResponseCode.genericError.rawValue])
    }

    @Test func fifthClientRefused() {
        let h = Harness()
        #expect((1...4).allSatisfy { h.connect($0) })
        #expect(!h.connect(5))
    }

    @Test func badFrameClosesClient() {
        let h = Harness()
        h.connect(1)
        h.core.receive(hex("02 01 01 00 00 00"), from: 1)
        #expect(h.closed == [1])
    }
}

struct BuiltInInterceptorTests {
    let cp = FTMSUUID.controlPointID

    @Test func gradeScaleHalves() {
        guard case .forward(let d) = GradeScaleInterceptor(factor: 0.5).clientWrite(cp, hex("11 00 00 EE 00 28 33"), from: 1)
        else { Issue.record(); return }
        #expect(d == hex("11 00 00 77 00 28 33"))
    }

    @Test func ergCapClamps() {
        guard case .forward(let d) = ErgCapInterceptor(maxW: 300).clientWrite(cp, hex("05 90 01"), from: 1)
        else { Issue.record(); return }
        #expect(d == hex("05 2C 01"))
    }

    @Test func powerOffsetAdds() {
        let ibd = hex("44 00 2f 01 a0 00 64 00")  // speed, cadence 80, power 100
        guard case .forward(let d) = PowerOffsetInterceptor(offsetW: 10).trainerValue(FTMSUUID.indoorBikeDataID, ibd)
        else { Issue.record(); return }
        #expect(IndoorBikeData(d)?.powerW == 110)
    }
}
