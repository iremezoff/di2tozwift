import Foundation
import Testing
@testable import DirConCore

struct FTMSTests {
    @Test func decodeZwiftSim() throws {
        let bytes = hex("11 00 00 EE 00 28 33")
        let cmd = try #require(ControlCommand(bytes))
        guard case .simulation(let p) = cmd else { Issue.record("not simulation: \(cmd)"); return }
        #expect(p.windMS == 0)
        #expect(abs(p.gradePct - 2.38) < 1e-9)
        #expect(abs(p.crr - 0.0040) < 1e-12)
        #expect(abs(p.cw - 0.51) < 1e-12)
        #expect(cmd.opCode == 0x11)
        #expect(cmd.encoded() == bytes)
    }

    @Test func decodeTargetPower() {
        #expect(ControlCommand(hex("05 96 00")) == .setTargetPower(150))
        #expect(ControlCommand(hex("00")) == .requestControl)
        #expect(ControlCommand(hex("12 3A 52")) == .wheelCircumference(0x523A))
        #expect(ControlCommand.setTargetPower(150).encoded() == hex("05 96 00"))
    }

    @Test func controlResponse() {
        #expect(ControlResponse(hex("80 00 01")) == ControlResponse(requestOp: 0, result: 1))
        #expect(ControlResponse(hex("11 00 01")) == nil)
        #expect(ControlResponse(requestOp: 0x11, result: ControlResponse.notPermitted).encoded() == hex("80 11 05"))
    }

    @Test func t600IndoorBikeData() throws {
        let d = try #require(IndoorBikeData(hex("44002f01000000003d00000019002409151615")))
        #expect(d.speedKmh == 3.03)
        #expect(d.cadenceRpm == 0)
        #expect(d.powerW == 0)
        #expect(d.heartRate == nil)
        #expect(IndoorBikeData(hex("4400 2f01 00")) == nil)  // cadence cut off
    }

    @Test func featureForZwift() {
        #expect(FeatureBits.forZwift(T600Profile.feature) == hex("02 40 00 00 08 20 00 00"))
        #expect(FeatureBits.forZwift(hex("00 00 00 00 00 60 00 00")) == hex("00 00 00 00 08 20 00 00"))
        #expect(FeatureBits.targetSettings(T600Profile.feature) == 0x2008)
    }

    @Test func malformedSimIsOther() {
        #expect(ControlCommand(hex("11 00 00")) == .other(op: 0x11, params: hex("00 00")))
        #expect(ControlCommand(Data()) == nil)
    }

    @Test func describeSim() {
        #expect(describe(ControlCommand(hex("11 00 00 EE 00 28 33"))!) ==
                "SIM wind 0.000 m/s grade 2.38% Crr 0.0040 Cw 0.51")
    }
}
