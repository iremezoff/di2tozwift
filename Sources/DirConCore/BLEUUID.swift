import Foundation

/// A 128-bit Bluetooth UUID stored as 16 bytes in textual (left-to-right) order,
/// which is also the order DirCon puts them on the wire.
public struct BLEUUID: Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// Bluetooth SIG base UUID 0000xxxx-0000-1000-8000-00805F9B34FB.
    static let sigBase: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                   0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB]

    public init(short: UInt16) {
        var b = Self.sigBase
        b[2] = UInt8(short >> 8)
        b[3] = UInt8(short & 0xFF)
        bytes = b
    }

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 16 else { return nil }
        self.bytes = Array(bytes)
    }

    /// Accepts "2AD9", "0x2AD9" and the full 36-character form.
    public init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        if s.count == 4, let v = UInt16(s, radix: 16) {
            self.init(short: v)
            return
        }
        let hexDigits = s.filter { $0 != "-" }
        guard s.count == 36, hexDigits.count == 32 else { return nil }
        var out: [UInt8] = []
        var i = hexDigits.startIndex
        while i < hexDigits.endIndex {
            let j = hexDigits.index(i, offsetBy: 2)
            guard let byte = UInt8(hexDigits[i..<j], radix: 16) else { return nil }
            out.append(byte)
            i = j
        }
        self.init(bytes: out)
    }

    public var isSIGBase: Bool {
        bytes[0] == 0 && bytes[1] == 0 && Array(bytes[4...]) == Array(Self.sigBase[4...])
    }

    /// The 16-bit SIG alias, nil for vendor UUIDs.
    public var short: UInt16? {
        isSIGBase ? UInt16(bytes[2]) << 8 | UInt16(bytes[3]) : nil
    }

    public var data: Data { Data(bytes) }

    public var description: String {
        if let s = short { return String(format: "%04X", s) }
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { r -> String in
            let a = h.index(h.startIndex, offsetBy: r.lowerBound)
            let b = h.index(h.startIndex, offsetBy: r.upperBound)
            return String(h[a..<b])
        }
        return parts.joined(separator: "-")
    }
}
