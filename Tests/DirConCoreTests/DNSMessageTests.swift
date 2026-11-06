import Foundation
import Testing
@testable import DirConCore

private let records = ServiceRecords(
    instance: "DirCon Proxy 1A2B", host: "dirconproxy-1a2b", port: 36866, ipv4: [192, 168, 1, 20],
    txt: ["serial-number": "P010224701G158W0035", "mac-address": "AA-BB-CC-DD-EE-FF", "ble-service-uuids": "0x1826,0x1818"])

/// Minimal reader for the response the responder produces (no compression is used there).
private struct RR { let name: String; let type: UInt16; let cls: UInt16; let ttl: UInt32; let rdata: [UInt8] }
private func readName(_ b: [UInt8], _ o: inout Int) -> String {
    var labels: [String] = []
    while b[o] != 0 {
        let n = Int(b[o]); o += 1
        labels.append(String(decoding: b[o..<o + n], as: UTF8.self)); o += n
    }
    o += 1
    return labels.joined(separator: ".")
}
private func answers(_ d: Data) -> (an: Int, ar: Int, rrs: [RR]) {
    let b = [UInt8](d)
    func u16(_ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    let an = Int(u16(6)), ar = Int(u16(10))
    var o = 12
    var out: [RR] = []
    for _ in 0..<(an + ar) {
        let name = readName(b, &o)
        let type = u16(o), cls = u16(o + 2)
        let ttl = UInt32(u16(o + 4)) << 16 | UInt32(u16(o + 6))
        let len = Int(u16(o + 8)); o += 10
        out.append(RR(name: name, type: type, cls: cls, ttl: ttl, rdata: Array(b[o..<o + len]))); o += len
    }
    return (an, ar, out)
}

struct DNSMessageTests {
    @Test func responseHasFourAnswers() {
        let r = answers(DNSMessage.response(for: records))
        #expect(r.an == 4 && r.ar == 0)
        #expect(r.rrs.map(\.type) == [12, 33, 16, 1])
        #expect(r.rrs.map(\.ttl) == [4500, 120, 4500, 120])
        #expect(r.rrs[0].name == "_wahoo-fitness-tnp._tcp.local")
        var o = 0
        #expect(readName(r.rrs[0].rdata, &o) == "DirCon Proxy 1A2B._wahoo-fitness-tnp._tcp.local")
        let srv = r.rrs[1].rdata
        #expect(Int(srv[4]) << 8 | Int(srv[5]) == 36866)
        var so = 6
        #expect(readName(srv, &so) == "dirconproxy-1a2b.local")
        let txt = String(decoding: r.rrs[2].rdata, as: UTF8.self)
        #expect(txt.contains("serial-number=P010224701G158W0035"))
        #expect(txt.contains("mac-address=AA-BB-CC-DD-EE-FF"))
        #expect(txt.contains("ble-service-uuids=0x1826,0x1818"))
        #expect(r.rrs[3].name == "dirconproxy-1a2b.local")
        #expect(r.rrs[3].rdata == [192, 168, 1, 20])
    }

    @Test func goodbyeHasZeroTTL() {
        #expect(answers(DNSMessage.response(for: records, ttlScale: 0)).rrs.allSatisfy { $0.ttl == 0 })
    }

    @Test func parsesCompressedQuery() throws {
        // Header: id 0x1234, query, 2 questions.
        var q: [UInt8] = [0x12, 0x34, 0x00, 0x00, 0x00, 0x02, 0, 0, 0, 0, 0, 0]
        // Q1 at offset 12: _wahoo-fitness-tnp._tcp.local PTR IN with the QU bit.
        for label in ["_wahoo-fitness-tnp", "_tcp", "local"] { q.append(UInt8(label.utf8.count)); q += Array(label.utf8) }
        q += [0, 0x00, 0x0C, 0x80, 0x01]
        // Q2: "DirCon Proxy 1A2B" + pointer to offset 12, SRV IN.
        let inst = "DirCon Proxy 1A2B"
        q.append(UInt8(inst.utf8.count)); q += Array(inst.utf8)
        q += [0xC0, 0x0C, 0x00, 0x21, 0x00, 0x01]
        let parsed = try #require(DNSMessage.parseQuestions(Data(q)))
        #expect(parsed.id == 0x1234 && parsed.isQuery)
        #expect(parsed.questions == [
            DNSQuestion(name: "_wahoo-fitness-tnp._tcp.local", type: 12, unicastResponse: true),
            DNSQuestion(name: "DirCon Proxy 1A2B._wahoo-fitness-tnp._tcp.local", type: 33, unicastResponse: false),
        ])
    }

    @Test func rejectsPointerLoop() {
        let q: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1]
        #expect(DNSMessage.parseQuestions(Data(q)) == nil)
    }

    @Test func ignoresOtherServices() {
        func ask(_ n: String, _ t: UInt16) -> Bool {
            DNSMessage.shouldAnswer(DNSQuestion(name: n, type: t, unicastResponse: false), records: records)
        }
        #expect(!ask("_zap._tcp.local", 12))
        #expect(ask("_wahoo-fitness-tnp._tcp.local", 12))
        #expect(ask("_WAHOO-fitness-tnp._tcp.local.", 12))
        #expect(ask("DirCon Proxy 1A2B._wahoo-fitness-tnp._tcp.local", 33))
        #expect(ask("DirCon Proxy 1A2B._wahoo-fitness-tnp._tcp.local", 16))
        #expect(ask("DirCon Proxy 1A2B._wahoo-fitness-tnp._tcp.local", 255))
        #expect(ask("dirconproxy-1a2b.local", 1))
        #expect(!ask("dirconproxy-1a2b.local", 28))
        #expect(!ask("other-host.local", 1))
    }

    @Test func txtFormatting() {
        #expect(TXTFormat().macAddress([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]) == "AA-BB-CC-DD-EE-FF")
        var colon = TXTFormat()
        colon.macSeparator = ":"
        #expect(colon.macAddress([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x0F]) == "AA:BB:CC:DD:EE:0F")
    }
}
