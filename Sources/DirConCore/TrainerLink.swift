import Foundation

public enum TrainerState: Equatable {
    case scanning, connecting, ready, reconnecting, offline
}

public enum TrainerError: Error, Equatable {
    case timeout, offline, failed(String)
}

/// All delegate calls arrive on the core queue.
public protocol TrainerLinkDelegate: AnyObject {
    func trainerStateChanged(_ s: TrainerState)
    func trainerValue(_ value: Data, for id: CharacteristicID)
}

/// The proxy's view of the trainer. Call on the core queue; completions arrive there too.
/// Control Point indications are always on and are not managed through `setNotify`.
/// After a reconnect, notifications are off until `setNotify(true)` is called again.
public protocol TrainerLink: AnyObject {
    var delegate: TrainerLinkDelegate? { get set }
    var state: TrainerState { get }
    var name: String { get }
    var identifier: String { get }
    var services: [GattService] { get }
    func cachedValue(_ id: CharacteristicID) -> Data?
    func start()
    func stop()
    func read(_ id: CharacteristicID, completion: @escaping (Result<Data, TrainerError>) -> Void)
    func write(_ id: CharacteristicID, _ value: Data, completion: @escaping (Result<Void, TrainerError>) -> Void)
    func setNotify(_ id: CharacteristicID, _ on: Bool)
}
