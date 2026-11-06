import ArgumentParser
import DirConCore
import Foundation

struct DirConProxy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dirconproxy",
        abstract: "Serves a Bluetooth FTMS trainer to Zwift on this Mac over Wahoo DirCon, with virtual Shimano shifting.",
        subcommands: [RunCommand.self, ScanCommand.self, DoctorCommand.self],
        defaultSubcommand: RunCommand.self
    )
}

enum ExitCode32: Int32 {
    case ok = 0, usage = 1, bluetooth = 2, network = 3
}

/// Status lines and logs go to stderr.
enum Out {
    static var debug = false
    private static let started = Date()

    static func status(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func log(_ s: String) {
        guard debug else { return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        FileHandle.standardError.write(Data(String(format: "%7d ms  %@\n", ms, s).utf8))
    }

    static func fail(_ s: String, _ code: ExitCode32) -> Never {
        Terminal.restore()
        status("error: " + s)
        exit(code.rawValue)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
DirConProxy.main()
