import Foundation

public enum ShiftDirection {
    /// Harder, toward 52×11.
    case up
    /// Easier, toward 36×34.
    case down
}

/// A source of shift events (keyboard now, Di2 D-FLY later). Callbacks arrive on the core queue.
public protocol ShiftInput: AnyObject {
    /// Returns false when the shift changed nothing (already at that end of the ladder).
    var onShift: ((ShiftDirection) -> Bool)? { get set }
    func start()
    func stop()
}
