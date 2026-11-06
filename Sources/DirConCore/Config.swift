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

/// Di2 D-FLY shift input. Off by default.
public struct Di2Config: Codable, Equatable {
    public var enabled = false
    /// Advertised name of the rear derailleur; nil = the first Di2 found.
    public var name: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name)
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
    public var di2 = Di2Config()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case trainer, name, port, mdns, txt
        case serialNumber = "serial_number"
        case notificationSeq = "notification_seq"
        case interceptors, shifting, di2
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
        di2 = try c.decodeIfPresent(Di2Config.self, forKey: .di2) ?? d.di2
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
