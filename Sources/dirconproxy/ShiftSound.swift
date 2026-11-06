import AudioToolbox
import DirConCore
import Foundation

/// Plays a system sound per shift: one for harder, one for easier, one for "already at the end".
/// Sounds are loaded once, so playing is immediate and never blocks the core queue.
final class ShiftSound {
    private var ids: [String: SystemSoundID] = [:]
    private let config: SoundConfig

    init(_ config: SoundConfig, log: (String) -> Void) {
        self.config = config
        for name in Set([config.up, config.down, config.limit]) {
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            var id: SystemSoundID = 0
            if FileManager.default.fileExists(atPath: url.path),
               AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr {
                ids[name] = id
            } else {
                log("sound \(name) not found in /System/Library/Sounds")
            }
        }
    }

    func play(_ r: ShiftResult) {
        let name: String
        switch r {
        case .shifted(.up, _): name = config.up
        case .shifted(.down, _): name = config.down
        case .limit: name = config.limit
        }
        if let id = ids[name] { AudioServicesPlaySystemSound(id) }
    }
}
