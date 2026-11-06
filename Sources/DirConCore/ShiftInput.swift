import Foundation

public enum ShiftDirection {
    /// Harder, toward 52×11.
    case up
    /// Easier, toward 36×34.
    case down
}

/// A source of shift events (keyboard now, Di2 D-FLY later). Callbacks arrive on the core queue.
public protocol ShiftInput: AnyObject {
    var onShift: ((ShiftDirection) -> Void)? { get set }
    func start()
    func stop()
}
