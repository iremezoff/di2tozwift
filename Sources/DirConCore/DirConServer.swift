import Foundation
import Network

/// TCP side of DirCon: one NWListener, one NWConnection per client, bytes in and out of ProxyCore.
/// Everything runs on the core queue.
public final class DirConServer {
    private let core: ProxyCore
    private let port: UInt16
    private let queue: DispatchQueue
    private let bonjourService: NWListener.Service?
    private let status: (String) -> Void

    private var listener: NWListener?
    private var connections: [ClientID: NWConnection] = [:]
    private var nextID: ClientID = 1

    public init(core: ProxyCore, port: UInt16, queue: DispatchQueue,
                bonjourService: NWListener.Service? = nil, status: @escaping (String) -> Void) {
        self.core = core
        self.port = port
        self.queue = queue
        self.bonjourService = bonjourService
        self.status = status
    }

    /// `ready` gets the bound port, or the error (e.g. port in use). Called once.
    public func start(ready: @escaping (Result<UInt16, Error>) -> Void) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = false

        let l: NWListener
        do {
            if port == 0 {
                l = try NWListener(using: params)
            } else {
                l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            }
        } catch {
            return ready(.failure(error))
        }
        l.service = bonjourService
        var reported = false
        l.stateUpdateHandler = { [weak self, weak l] s in
            switch s {
            case .ready:
                guard !reported else { return }
                reported = true
                ready(.success(l?.port?.rawValue ?? 0))
            case .failed(let e):
                self?.listener?.cancel()
                self?.listener = nil
                if !reported {
                    reported = true
                    ready(.failure(e))
                } else {
                    self?.status("DirCon listener failed: \(e)")
                }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        core.onCloseClient = { [weak self] id in self?.drop(id, tellCore: false) }
        listener = l
        l.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { drop(id, tellCore: true) }
    }

    private func describe(_ c: NWConnection) -> String {
        if case .hostPort(let host, let port) = c.endpoint {
            var h = "\(host)"
            if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
            return "\(h):\(port)"
        }
        return "\(c.endpoint)"
    }

    private func accept(_ c: NWConnection) {
        let id = nextID
        nextID += 1
        let accepted = core.clientConnected(id) { data in
            c.send(content: data, completion: .contentProcessed { _ in })
        }
        guard accepted else {
            status("refused client \(describe(c)): \(ProxyCore.maxClients) already connected")
            c.cancel()
            return
        }
        connections[id] = c
        status("client connected \(describe(c))")
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.drop(id, tellCore: true)
            default: break
            }
        }
        c.start(queue: queue)
        receive(id, c)
    }

    private func receive(_ id: ClientID, _ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            if let data, !data.isEmpty { self.core.receive(data, from: id) }
            if complete || error != nil {
                self.drop(id, tellCore: true)
            } else if self.connections[id] != nil {
                self.receive(id, c)
            }
        }
    }

    private func drop(_ id: ClientID, tellCore: Bool) {
        guard let c = connections.removeValue(forKey: id) else { return }
        if tellCore { core.clientDisconnected(id) }
        status("client disconnected \(describe(c))")
        c.cancel()
    }
}
