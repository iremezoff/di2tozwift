import Foundation
import Network

public enum NetworkError: Error, CustomStringConvertible {
    case socket(String)
    case noIPv4
    public var description: String {
        switch self {
        case .socket(let s): return s
        case .noIPv4: return "no active IPv4 address"
        }
    }
}

public protocol Advertiser: AnyObject {
    func start(_ records: ServiceRecords) throws
    func update(_ records: ServiceRecords)
    /// Sends goodbye records.
    func stop()
}

/// Own mDNS responder for `_wahoo-fitness-tnp._tcp`: every answer carries PTR, SRV, TXT and A in Answers.
/// Shares UDP 5353 with the system's mDNSResponder via SO_REUSEPORT. Runs on the core queue.
public final class MDNSResponder: Advertiser {
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var monitor: NWPathMonitor?
    private var records: ServiceRecords?
    private var interfaceAddress = in_addr(s_addr: INADDR_ANY)

    /// Called when the Mac's IPv4 address changes; returns updated records (nil = no IPv4 now).
    public var recordsForNewAddress: (() -> ServiceRecords?)?

    public init(queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.queue = queue
        self.log = log
    }

    public func start(_ records: ServiceRecords) throws {
        self.records = records
        try openSocket(records.ipv4)
        announce(times: 3)
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in self?.pathChanged() }
        m.start(queue: queue)
        monitor = m
    }

    public func update(_ records: ServiceRecords) {
        let old = self.records
        self.records = records
        if old?.ipv4 != records.ipv4 { joinGroup(records.ipv4) }
        announce(times: 3)
    }

    public func stop() {
        if let r = records { send(DNSMessage.response(for: r, ttlScale: 0), to: nil) }
        monitor?.cancel()
        monitor = nil
        source?.cancel()
        source = nil
        records = nil
    }

    // MARK: Socket

    private func openSocket(_ ipv4: [UInt8]) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NetworkError.socket("mDNS socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(5353).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let e = String(cString: strerror(errno))
            close(fd)
            fd = -1
            throw NetworkError.socket("bind UDP 5353: \(e)")
        }
        var loop: UInt8 = 1
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        var ttl: UInt8 = 255
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        joinGroup(ipv4)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let sock = fd
        src.setEventHandler { [weak self] in self?.receive() }
        src.setCancelHandler { close(sock) }
        src.resume()
        source = src
    }

    private func joinGroup(_ ipv4: [UInt8]) {
        guard fd >= 0, ipv4.count == 4 else { return }
        var ifAddr = in_addr()
        withUnsafeMutableBytes(of: &ifAddr.s_addr) { $0.copyBytes(from: ipv4) }
        var mreq = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr("224.0.0.251")), imr_interface: ifAddr)
        if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) != 0, errno != EADDRINUSE {
            log("mDNS: join 224.0.0.251 failed: \(String(cString: strerror(errno)))")
        }
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
        interfaceAddress = ifAddr
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 9000)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0, let records, let q = DNSMessage.parseQuestions(Data(buf[0..<n])), q.isQuery else { return }
        let matching = q.questions.filter { DNSMessage.shouldAnswer($0, records: records) }
        guard !matching.isEmpty else { return }
        let response = DNSMessage.response(for: records)
        if matching.contains(where: \.unicastResponse) {
            send(response, to: from)
        } else {
            send(response, to: nil)
        }
    }

    /// nil = multicast to 224.0.0.251:5353.
    private func send(_ data: Data, to dest: sockaddr_in?) {
        guard fd >= 0 else { return }
        var addr = dest ?? {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = in_port_t(5353).bigEndian
            a.sin_addr.s_addr = inet_addr("224.0.0.251")
            return a
        }()
        let rc = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if rc < 0 { log("mDNS send failed: \(String(cString: strerror(errno)))") }
    }

    private func announce(times: Int) {
        guard times > 0, let r = records else { return }
        send(DNSMessage.response(for: r), to: nil)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.records == r else { return }
            self.announce(times: times - 1)
        }
    }

    private func pathChanged() {
        guard records != nil, let fresh = recordsForNewAddress?() else { return }
        if fresh.ipv4 != records?.ipv4 {
            log("IPv4 address changed to \(fresh.ipv4.map(String.init).joined(separator: ".")); re-announcing")
            update(fresh)
        }
    }
}

/// Bonjour fallback: the DirCon listener registers the service with the system (SRV/TXT/A end up
/// under Additional Records). Pass `service(for:)` to `DirConServer`; never run both modes at once.
public enum BonjourService {
    public static func service(for r: ServiceRecords) -> NWListener.Service {
        NWListener.Service(name: r.instance, type: "_wahoo-fitness-tnp._tcp", domain: "local.",
                           txtRecord: NWTXTRecord(r.txt))
    }
}
