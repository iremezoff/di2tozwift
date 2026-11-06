import Foundation
import Testing
@testable import DirConCore

struct ShiftFeedbackTests {
    @Test func shiftReportsResult() {
        let vs = VirtualShifting(config: ShiftingConfig(), status: { _ in }, log: { _ in })
        var results: [ShiftResult] = []
        vs.onShiftResult = { results.append($0) }
        vs.shift(.up)    // 21 → 22
        vs.shift(.down)  // 22 → 21
        vs.shift(.up); vs.shift(.up); vs.shift(.up)  // → 24
        vs.shift(.up)    // limit
        #expect(results.count == 6)
        #expect(results[0] == .shifted(.up, gear: 22))
        #expect(results[1] == .shifted(.down, gear: 21))
        #expect(results[4] == .shifted(.up, gear: 24))
        #expect(results[5] == .limit(.up))
    }

    @Test func soundConfigDefaults() throws {
        let c = try JSONDecoder().decode(ProxyConfig.self, from: Data(#"{"sound":{"down":"Morse"}}"#.utf8))
        #expect(c.sound.enabled)
        #expect(c.sound.up == "Tink")
        #expect(c.sound.down == "Morse")
        #expect(c.sound.limit == "Basso")
        #expect(ProxyConfig().sound == SoundConfig())
    }
}
