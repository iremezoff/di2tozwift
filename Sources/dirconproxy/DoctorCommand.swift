import ArgumentParser
import CoreBluetooth
import DirConCore
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check Bluetooth permission, IPv4, UDP 5353 and TCP 36866.")

    @Option(help: "DirCon TCP port to check.") var port: UInt16 = 36866

    func run() throws {
        var ok = true
        func check(_ good: Bool, _ what: String, _ hint: String = "") {
            print("\(good ? "✓" : "✗") \(what)\(good || hint.isEmpty ? "" : " — \(hint)")")
            ok = ok && good
        }

        let auth = CBManager.authorization
        check(auth == .allowedAlways || auth == .notDetermined,
              "Bluetooth authorization: \(auth == .allowedAlways ? "allowed" : auth == .notDetermined ? "not asked yet" : "denied")",
              "allow your terminal app in System Settings › Privacy & Security › Bluetooth")

        if let net = NetworkInfo.activeIPv4() {
            check(true, "IPv4 \(net.address.map(String.init).joined(separator: ".")) on \(net.interface)")
        } else {
            check(false, "active IPv4 address", "connect to a network; Zwift finds the proxy through the LAN address")
        }

        check(bindable(type: SOCK_DGRAM, port: 5353, reusePort: true), "UDP 5353 can be shared (SO_REUSEPORT)",
              "another program holds 5353 exclusively; try --mdns bonjour")
        check(bindable(type: SOCK_STREAM, port: port, reusePort: false), "TCP \(port) is free",
              "another program (maybe another dirconproxy) uses it")

        print("Also check: Zwift has Local Network access (System Settings › Privacy & Security › Local Network).")
        throw ExitCode(ok ? 0 : 1)
    }

    private func bindable(type: Int32, port: UInt16, reusePort: Bool) -> Bool {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        if reusePort {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = INADDR_ANY
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}
