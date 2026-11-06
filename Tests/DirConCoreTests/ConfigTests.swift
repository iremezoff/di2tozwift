import Foundation
import Testing
@testable import DirConCore

struct ConfigTests {
    @Test func configDefaults() throws {
        let c = try JSONDecoder().decode(ProxyConfig.self, from: Data("{}".utf8))
        #expect(c.port == 36866)
        #expect(c.mdns == .own)
        #expect(c.trainer == nil)
        #expect(c.notificationSeq == .zero)
        #expect(c.shifting.enabled)
        #expect(c.shifting.start == .identity)
        #expect(c.shifting.strategy == .auto)
        #expect(c.shifting.rings == [52, 36])
        #expect(c.txt.serviceUUIDs == "0x1826,0x1818")
        #expect(c.interceptors == InterceptorConfig())
    }

    @Test func configRoundTrip() throws {
        var c = ProxyConfig()
        c.trainer = "3890D5FC-83F4-FAEB-9B56-E65F3054AA8D"
        c.name = "My Proxy"
        c.shifting.start = .number(12)
        c.interceptors.ergCapW = 300
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        try c.save(to: url)
        #expect(try ProxyConfig.load(from: url) == c)
    }

    @Test func missingFileGivesDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        #expect(try ProxyConfig.load(from: url) == ProxyConfig())
    }

    @Test func configSnakeCaseKeys() throws {
        let json = #"{"shifting":{"min_step_pct":4,"wheel_circumference_mm":2096,"start":3},"notification_seq":"counter","interceptors":{"grade_scale":0.5}}"#
        let c = try JSONDecoder().decode(ProxyConfig.self, from: Data(json.utf8))
        #expect(c.shifting.minStepPct == 4)
        #expect(c.shifting.wheelCircumferenceMM == 2096)
        #expect(c.shifting.start == .number(3))
        #expect(c.notificationSeq == .counter)
        #expect(c.interceptors.gradeScale == 0.5)
    }

    @Test func badConfigThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ProxyConfig.self, from: Data(#"{"mdns":"carrier-pigeon"}"#.utf8))
        }
    }

    @Test func di2ConfigDefaultsOffAndDecodes() throws {
        #expect(ProxyConfig().di2 == Di2Config())
        #expect(!ProxyConfig().di2.enabled)
        let c = try JSONDecoder().decode(ProxyConfig.self, from: Data(#"{"di2":{"enabled":true,"name":"ireme   29C"}}"#.utf8))
        #expect(c.di2.enabled)
        #expect(c.di2.name == "ireme   29C")
    }
}
