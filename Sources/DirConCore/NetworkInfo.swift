import Foundation

public enum NetworkInfo {
    /// The first up, running, non-loopback interface with IPv4 (en0 preferred), with its MAC address.
    public static func activeIPv4() -> (interface: String, address: [UInt8], mac: [UInt8])? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var v4: [(String, [UInt8])] = []
        var macs: [String: [UInt8]] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            if sa.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 {
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let b = withUnsafeBytes(of: addr) { Array($0) }  // network order = textual order
                if b[0] == 169, b[1] == 254 { continue }        // skip link-local
                v4.append((name, b))
            } else if sa.pointee.sa_family == UInt8(AF_LINK) {
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let d = dl.pointee
                    guard d.sdl_alen == 6 else { return }
                    let base = UnsafeRawPointer(dl).advanced(by: 8 + Int(d.sdl_nlen))  // sdl_data starts at offset 8
                    macs[name] = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: 6))
                }
            }
        }
        guard let pick = v4.first(where: { $0.0 == "en0" }) ?? v4.first(where: { $0.0.hasPrefix("en") }) ?? v4.first
        else { return nil }
        return (pick.0, pick.1, macs[pick.0] ?? [0, 0, 0, 0, 0, 0])
    }
}
