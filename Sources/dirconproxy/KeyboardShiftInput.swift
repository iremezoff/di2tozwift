import DirConCore
import Foundation

/// Terminal keys shift: `]` or Up = harder, `[` or Down = easier. Active only on an interactive terminal.
/// Raw mode is always undone: on stop(), at exit and from the signal handlers.
final class KeyboardShiftInput: ShiftInput {
    var onShift: ((ShiftDirection) -> Void)?
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var escape: [UInt8] = []

    static var isAvailable: Bool { isatty(STDIN_FILENO) == 1 }

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
        guard Self.isAvailable, source == nil else { return }
        Terminal.enterRawMode()
        let s = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        s.setEventHandler { [weak self] in self?.readKeys() }
        s.resume()
        source = s
    }

    func stop() {
        source?.cancel()
        source = nil
        Terminal.restore()
    }

    private func readKeys() {
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(STDIN_FILENO, &buf, buf.count)
        guard n > 0 else { return }
        for b in buf[0..<n] { handle(b) }
    }

    private func handle(_ b: UInt8) {
        if !escape.isEmpty || b == 0x1B {
            escape.append(b)
            if escape.count == 3 {
                if escape == [0x1B, 0x5B, 0x41] { onShift?(.up) }    // Up arrow
                if escape == [0x1B, 0x5B, 0x42] { onShift?(.down) }  // Down arrow
                escape = []
            } else if escape.count == 2, escape[1] != 0x5B {
                escape = []
            }
            return
        }
        switch b {
        case UInt8(ascii: "]"): onShift?(.up)
        case UInt8(ascii: "["): onShift?(.down)
        default: break
        }
    }
}

/// Saves the terminal settings once and restores them however the process ends.
enum Terminal {
    private static var original: termios?

    static func enterRawMode() {
        var t = termios()
        guard tcgetattr(STDIN_FILENO, &t) == 0 else { return }
        if original == nil {
            original = t
            atexit { Terminal.restore() }
        }
        t.c_lflag &= ~tcflag_t(ICANON | ECHO)  // keep ISIG so Ctrl-C still raises SIGINT
        withUnsafeMutablePointer(to: &t.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }

    static func restore() {
        guard var t = original else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
}
