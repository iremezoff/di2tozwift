import Foundation
import Testing
@testable import DirConCore

func hex(_ s: String) -> Data {
    let clean = s.filter { !$0.isWhitespace }
    var out = Data()
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

let ftmsUUIDHex = "00 00 18 26 00 00 10 00 80 00 00 80 5F 9B 34 FB"
let cpsUUIDHex = "00 00 18 18 00 00 10 00 80 00 00 80 5F 9B 34 FB"
let ibdUUIDHex = "00 00 2A D2 00 00 10 00 80 00 00 80 5F 9B 34 FB"
let cpUUIDHex = "00 00 2A D9 00 00 10 00 80 00 00 80 5F 9B 34 FB"

struct DirConCodecTests {
    @Test func discoverServicesRoundTrip() throws {
        var parser = FrameParser()
        let frames = try parser.append(hex("01 01 01 00 00 00"))
        #expect(frames == [Frame(type: 1, seq: 1, code: 0, data: Data())])
        #expect(DirConRequest.decode(frames[0]) == .discoverServices)

        let body = BLEUUID(short: 0x1826).data + BLEUUID(short: 0x1818).data
        let response = Frame.response(to: frames[0], code: .success, data: body)
        #expect(response.encoded() == hex("01 01 01 00 00 20" + ftmsUUIDHex + cpsUUIDHex))
    }

    @Test func enableNotificationsDecode() throws {
        var parser = FrameParser()
        let frames = try parser.append(hex("01 05 05 00 00 11" + ibdUUIDHex + "01"))
        #expect(frames.count == 1)
        #expect(DirConRequest.decode(frames[0]) == .enableNotifications(BLEUUID(short: 0x2AD2), true))
        let response = Frame.response(to: frames[0], code: .success, data: BLEUUID(short: 0x2AD2).data)
        #expect(response.encoded() == hex("01 05 05 00 00 10" + ibdUUIDHex))
    }

    @Test func controlPointIndicationEncode() {
        let frame = Frame.notification(BLEUUID(short: 0x2AD9), Data([0x80, 0x00, 0x01]))
        #expect(frame.encoded() == hex("01 06 00 00 00 13" + cpUUIDHex + "80 00 01"))
    }

    @Test func splitFrame() throws {
        let write = hex("01 04 07 00 00 11" + cpUUIDHex + "00")
        #expect(write.count == 23)
        var parser = FrameParser()
        #expect(try parser.append(write.prefix(10)).isEmpty)
        let frames = try parser.append(write.suffix(13))
        #expect(frames.count == 1)
        #expect(DirConRequest.decode(frames[0]) == .write(BLEUUID(short: 0x2AD9), Data([0x00])))
    }

    @Test func twoFramesInOneRead() throws {
        var parser = FrameParser()
        let frames = try parser.append(hex("01 01 01 00 00 00") + hex("01 03 02 00 00 10" + cpUUIDHex))
        #expect(frames.map(\.seq) == [1, 2])
        #expect(DirConRequest.decode(frames[1]) == .read(BLEUUID(short: 0x2AD9)))
    }

    @Test func oversizedLengthThrows() {
        var p1 = FrameParser()
        #expect(throws: FrameError.tooLong(513)) { try p1.append(hex("01 03 01 00 02 01")) }
        var p2 = FrameParser()
        #expect(throws: FrameError.badVersion(2)) { try p2.append(hex("02 01 01 00 00 00")) }
    }

    @Test func uuidForms() {
        #expect(BLEUUID(string: "0x1826") == BLEUUID(short: 0x1826))
        #expect(BLEUUID(string: "2AD9") == BLEUUID(short: 0x2AD9))
        #expect(BLEUUID(string: "00002ad9-0000-1000-8000-00805f9b34fb") == BLEUUID(short: 0x2AD9))
        #expect(BLEUUID(short: 0x2AD9).short == 0x2AD9)
        let vendor = BLEUUID(string: "8ce5cc01-0a4d-11e9-ab14-d663bd873d93")!
        #expect(vendor.isSIGBase == false)
        #expect(vendor.short == nil)
        #expect(vendor.description == "8ce5cc01-0a4d-11e9-ab14-d663bd873d93")
        #expect(BLEUUID(short: 0x2AD9).description == "2AD9")
    }
}
