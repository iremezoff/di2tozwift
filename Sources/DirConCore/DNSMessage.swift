import Foundation

public let dirConServiceType = "_wahoo-fitness-tnp._tcp.local"

/// What the proxy advertises: PTR, SRV, TXT and A, all in the Answers section.
public struct ServiceRecords: Equatable {
    public var instance: String
    /// Host label without ".local", e.g. "dirconproxy-1a2b".
    public var host: String
    public var port: UInt16
    public var ipv4: [UInt8]
    public var txt: [String: String]

    public init(instance: String, host: String, port: UInt16, ipv4: [UInt8], txt: [String: String]) {
        self.instance = instance
        self.host = host
        self.port = port
        self.ipv4 = ipv4
        self.txt = txt
    }

    public var instanceName: String { "\(instance).\(dirConServiceType)" }
    public var hostName: String { "\(host).local" }
}

/// TXT value formats; the exact formats Zwift expects are unverified, so they are configurable.
public struct TXTFormat: Codable, Equatable {
    public var serviceUUIDs = "0x1826,0x1818"
    public var macSeparator = "-"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case serviceUUIDs = "ble_service_uuids"
        case macSeparator = "mac_separator"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serviceUUIDs = try c.decodeIfPresent(String.self, forKey: .serviceUUIDs) ?? "0x1826,0x1818"
        macSeparator = try c.decodeIfPresent(String.self, forKey: .macSeparator) ?? "-"
    }

    public func macAddress(_ mac: [UInt8]) -> String {
        mac.map { String(format: "%02X", $0) }.joined(separator: macSeparator)
    }
}

public struct DNSQuestion: Equatable {
    public let name: String
    public let type: UInt16
    public let unicastResponse: Bool
}

public enum DNSMessage {
    static let typeA: UInt16 = 1, typePTR: UInt16 = 12, typeTXT: UInt16 = 16, typeSRV: UInt16 = 33, typeANY: UInt16 = 255

    /// Parses the header and question section, following compression pointers. nil if malformed.
    public static func parseQuestions(_ packet: Data) -> (id: UInt16, isQuery: Bool, questions: [DNSQuestion])? {
        let b = [UInt8](packet)
        guard b.count >= 12 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
        let id = u16(0)
        let isQuery = b[2] & 0x80 == 0
        let qd = Int(u16(4))
        var o = 12
        var questions: [DNSQuestion] = []
        for _ in 0..<qd {
            guard let name = readName(b, &o), o + 4 <= b.count else { return nil }
            let type = u16(o), cls = u16(o + 2)
            o += 4
            questions.append(DNSQuestion(name: name, type: type, unicastResponse: cls & 0x8000 != 0))
        }
        return (id, isQuery, questions)
    }

    private static func readName(_ b: [UInt8], _ o: inout Int) -> String? {
        var labels: [String] = []
        var pos = o
        var jumped = false
        var jumps = 0
        while true {
            guard pos < b.count else { return nil }
            let len = Int(b[pos])
            if len == 0 {
                pos += 1
                break
            }
            if len & 0xC0 == 0xC0 {
                guard pos + 1 < b.count, jumps < 16 else { return nil }
                let target = (len & 0x3F) << 8 | Int(b[pos + 1])
                guard target < pos else { return nil }  // pointers only go backwards: no loops
                if !jumped { o = pos + 2 }
                jumped = true
                jumps += 1
                pos = target
                continue
            }
            guard pos + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(pos + 1)..<(pos + 1 + len)], as: UTF8.self))
            pos += 1 + len
        }
        if !jumped { o = pos }
        return labels.joined(separator: ".")
    }

    private static func normalized(_ n: String) -> String {
        (n.hasSuffix(".") ? String(n.dropLast()) : n).lowercased()
    }

    public static func shouldAnswer(_ q: DNSQuestion, records: ServiceRecords) -> Bool {
        let n = normalized(q.name)
        if n == dirConServiceType { return q.type == typePTR || q.type == typeANY }
        if n == normalized(records.instanceName) { return [typeSRV, typeTXT, typeANY].contains(q.type) }
        if n == normalized(records.hostName) { return q.type == typeA || q.type == typeANY }
        return false
    }

    /// PTR, SRV, TXT and A, all in Answers. TTLs 4500/120/4500/120 × ttlScale (0 = goodbye).
    public static func response(for r: ServiceRecords, ttlScale: Double = 1) -> Data {
        var out: [UInt8] = [0, 0, 0x84, 0x00, 0, 0, 0, 4, 0, 0, 0, 0]
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func labels(_ s: String) -> [UInt8] {
            s.split(separator: ".").flatMap { l -> [UInt8] in
                let u = Array(l.utf8.prefix(63))
                return [UInt8(u.count)] + u
            }
        }
        let service = labels(dirConServiceType) + [0]
        // The instance is one label even if it contains spaces or dots.
        let instanceBytes = Array(r.instance.utf8.prefix(63))
        let instance = [UInt8(instanceBytes.count)] + instanceBytes + service
        let host = labels(r.hostName) + [0]

        func record(_ owner: [UInt8], _ type: UInt16, flush: Bool, ttl: UInt32, _ rdata: [UInt8]) {
            let t = UInt32((Double(ttl) * ttlScale).rounded())
            out += owner + be16(type) + be16(flush ? 0x8001 : 0x0001)
            out += [UInt8(t >> 24), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)]
            out += be16(UInt16(rdata.count)) + rdata
        }
        let txt = r.txt.keys.sorted().flatMap { k -> [UInt8] in
            let kv = Array("\(k)=\(r.txt[k]!)".utf8.prefix(255))
            return [UInt8(kv.count)] + kv
        }
        record(service, typePTR, flush: false, ttl: 4500, instance)
        record(instance, typeSRV, flush: true, ttl: 120, be16(0) + be16(0) + be16(r.port) + host)
        record(instance, typeTXT, flush: true, ttl: 4500, txt)
        record(host, typeA, flush: true, ttl: 120, r.ipv4)
        return Data(out)
    }
}
