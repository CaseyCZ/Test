import Foundation
import Network
import Combine

struct PlayCaptionDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var ip: String
}

@MainActor
final class PlayCaptionTV: ObservableObject {
    @Published var ip: String = UserDefaults.standard.string(forKey: "tvIP") ?? ""
    @Published var discovered: [PlayCaptionDevice] = []
    @Published var message = "Vyber „S telefonem“ v PlayCaption na televizi."
    private let queue = DispatchQueue(label: "cz.caseycz.playcaption.udp")
    private var listener: NWListener?
    private var sequence = UInt64(Date().timeIntervalSince1970 * 1000)

    func discover() {
        listener?.cancel()
        discovered = []
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        do {
            let listening = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 41988)!)
            listening.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listening.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor in self?.message = "Hledání selhalo: \(error.localizedDescription). IP lze zadat ručně." }
                }
            }
            listener = listening
            listening.start(queue: queue)
            message = "Hledám PlayCaption… Pokud TV nenajdu, zadej IP z její obrazovky."
        } catch {
            message = "Hledání není dostupné: \(error.localizedDescription). Zadej IP ručně."
        }
    }

    nonisolated private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let message = String(data: data, encoding: .utf8) {
                let parts = message.components(separatedBy: "\t")
                if parts.count >= 3 && parts[0] == "PLAYCAPTION_TV",
                   case .hostPort(let host, _) = connection.endpoint {
                    let device = PlayCaptionDevice(id: parts[1], name: parts[2], ip: host.debugDescription)
                    Task { @MainActor in
                        if !self.discovered.contains(where: { $0.id == device.id }) {
                            self.discovered.append(device)
                        }
                    }
                }
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    func sendSubtitle(_ subtitle: String, duration: Int) {
        let target = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            message = "Nejprve zadej IP televize."
            return
        }
        UserDefaults.standard.set(target, forKey: "tvIP")
        sequence += 1
        // PCT1 TAB seq TAB duration TAB subtitle TAB hint [optional layout/colors]
        let clean = subtitle.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "\\n")
        let payload = "PCT1\t\(sequence)\t\(max(0, duration))\t\(clean)\t"
        let connection = NWConnection(host: NWEndpoint.Host(target),
                                      port: NWEndpoint.Port(rawValue: 41989)!,
                                      using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.send(content: Data(payload.utf8), completion: .contentProcessed { error in
                    Task { @MainActor in
                        self?.message = error == nil
                            ? "Zpráva odeslána do \(target) (UDP bez potvrzení zobrazení)."
                            : "Chyba odesílání: \(error!.localizedDescription)"
                    }
                    connection.cancel()
                })
            case .failed(let error):
                Task { @MainActor in self?.message = "Nelze odeslat: \(error.localizedDescription)" }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }
}
