import Foundation
import Network

/// UDP transport for VISCA frames using the Network framework.
final class ViscaClient {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "ptzpad.visca.udp")

    /// Called on the client's queue. Hop to main before touching UI state.
    var onReply: ((ViscaReply) -> Void)?
    /// (socketReady, errorText)
    var onState: ((Bool, String?) -> Void)?

    func connect(host: String, port: UInt16) {
        disconnect()
        guard !host.isEmpty, let p = NWEndpoint.Port(rawValue: port) else {
            onState?(false, "Bad host or port")
            return
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                self.onState?(true, nil)
                self.receive(on: c)
            case .failed(let e):
                self.onState?(false, e.localizedDescription)
            case .waiting(let e):
                self.onState?(false, e.localizedDescription)
            case .cancelled:
                self.onState?(false, nil)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    func send(_ bytes: [UInt8]) {
        guard let c = connection, case .ready = c.state else { return }
        c.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for frame in Visca.split([UInt8](data)) {
                    self.onReply?(Visca.parse(frame))
                }
            }
            if error == nil, case .ready = c.state {
                self.receive(on: c)
            }
        }
    }
}
