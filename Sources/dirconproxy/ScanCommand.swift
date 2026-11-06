import ArgumentParser
import DirConCore
import Foundation

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scan", abstract: "List FTMS trainers in range.")

    @Option(help: "Seconds to scan.") var timeout: Double = 10

    func run() throws {
        let scanner = BLEScanner()
        Out.status("scanning \(Int(timeout)) s for FTMS trainers (spin the trainer to wake it)...")
        scanner.scan(seconds: timeout, queue: .main) { result in
            switch result {
            case .failure(let e):
                Out.fail(e.description, .bluetooth)
            case .success(let list):
                if list.isEmpty { Out.status("no trainer found: spin the trainer to wake it, then scan again") }
                for (i, t) in list.enumerated() {
                    print(String(format: "%2d  %@  %@  %d dBm", i + 1, t.id.uuidString, t.name, t.rssi))
                }
                withExtendedLifetime(scanner) { Foundation.exit(0) }
            }
        }
        dispatchMain()
    }
}
