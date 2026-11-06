import Foundation

public enum MDNSMode: String, Codable {
    case own, bonjour
}

/// Built-in interceptors; nil = off.
public struct InterceptorConfig: Codable, Equatable {
    public var gradeScale: Double?
    public var ergCapW: Int?
    public var powerOffsetW: Int?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case gradeScale = "grade_scale"
        case ergCapW = "erg_cap_w"
        case powerOffsetW = "power_offset_w"
    }
}

/// `~/.config/dirconproxy/config.json`. Missing keys take defaults; flags override the file.
public struct ProxyConfig: Codable, Equatable {
    public var trainer: String?
    public var name: String?
    public var port: UInt16 = 36866
    public var mdns = MDNSMode.own
    public var txt = TXTFormat()
    public var serialNumber: String?
    public var notificationSeq = NotificationSeq.zero
    public var interceptors = InterceptorConfig()
    public var shifting = ShiftingConfig()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case trainer, name, port, mdns, txt
        case serialNumber = "serial_number"
        case notificationSeq = "notification_seq"
        case interceptors, shifting
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProxyConfig()
        trainer = try c.decodeIfPresent(String.self, forKey: .trainer)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        mdns = try c.decodeIfPresent(MDNSMode.self, forKey: .mdns) ?? d.mdns
        txt = try c.decodeIfPresent(TXTFormat.self, forKey: .txt) ?? d.txt
        serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber)
        notificationSeq = try c.decodeIfPresent(NotificationSeq.self, forKey: .notificationSeq) ?? d.notificationSeq
        interceptors = try c.decodeIfPresent(InterceptorConfig.self, forKey: .interceptors) ?? d.interceptors
        shifting = try c.decodeIfPresent(ShiftingConfig.self, forKey: .shifting) ?? d.shifting
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dirconproxy/config.json")
    }

    /// A missing file gives the defaults; a malformed one throws.
    public static func load(from url: URL) throws -> ProxyConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return ProxyConfig() }
        return try JSONDecoder().decode(ProxyConfig.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }
}
