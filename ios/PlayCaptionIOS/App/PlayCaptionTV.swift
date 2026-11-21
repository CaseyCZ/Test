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
    @Published var pairingCode = ""
    @Published private(set) var pairedIP = UserDefaults.standard.string(forKey: "pairedTVIP") ?? ""
    @Published private(set) var pairingStatus = "Párování je volitelné – pro samotné titulky stačí IP televize."
    var isPaired: Bool { !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                         ip.trimmingCharacters(in: .whitespacesAndNewlines) == pairedIP }

    /// Received PCS1 DATA is sensitive: handle on device, never put the packet into diagnostics.
    var onPairingData: (([String]) -> Void)?
    @Published var message = "Vyber „S telefonem“ v PlayCaption na televizi."
    private let queue = DispatchQueue(label: "cz.caseycz.playcaption.udp")
    private var listener: NWListener?
    private var pairingConnection: NWConnection?
    private var repeatTask: Task<Void, Never>?
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


    /// Mirrors Android's PCS1 ZADOST/KOD handshake. Start this while the TV is
    /// displaying "Titulky z telefonu". The TV overlays a one-time four-digit PIN.
    func requestPairing() {
        pairingStatus = "Žádám televizi o párovací kód…"
        sendPairing("ZADOST\tPlayCaption iPhone")
    }

    func confirmPairing() {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 4, code.allSatisfy(\.isNumber) else {
            pairingStatus = "Zadej čtyřmístný kód z televize."
            return
        }
        pairingStatus = "Ověřuji kód na televizi…"
        sendPairing("KOD\t\(code)")
    }

    private func sendPairing(_ command: String) {
        let target = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            pairingStatus = "Nejprve vyber televizi nebo zadej její IP."
            return
        }
        pairingConnection?.cancel()
        let connection = NWConnection(host: .init(target),
                                      port: NWEndpoint.Port(rawValue: 41989)!,
                                      using: .udp)
        pairingConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                connection.receiveMessage { [weak self] data, _, _, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let data {
                            self.handlePairingReply(data, from: target)
                        } else {
                            self.pairingStatus = "Televize neodpověděla: \(error?.localizedDescription ?? "ověř IP a síť")."
                        }
                        connection.cancel()
                    }
                }
                connection.send(content: Data("PCS1\t\(command)".utf8),
                                completion: .contentProcessed { [weak self] error in
                    if let error {
                        Task { @MainActor in self?.pairingStatus = "Odeslání párování selhalo: \(error.localizedDescription)" }
                    }
                })
            case .failed(let error):
                Task { @MainActor in self?.pairingStatus = "Spojení s TV selhalo: \(error.localizedDescription)" }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func handlePairingReply(_ data: Data, from target: String) {
        guard let value = String(data: data, encoding: .utf8) else {
            pairingStatus = "Neplatná odpověď televize."
            return
        }
        let fields = value.components(separatedBy: "\t")
        guard fields.count >= 2, fields[0] == "PCS1" else {
            pairingStatus = "Neznámá odpověď televize."
            return
        }
        switch fields[1] {
        case "KOD":
            pairingStatus = "Na televizi se ukázal čtyřmístný kód. Opiš ho níže."
        case "DATA":
            // The reference TV may include Xbox refresh credentials here.
            // Never log, display, or persist the raw pairing response.
            onPairingData?(fields)
            pairedIP = target
            UserDefaults.standard.set(target, forKey: "pairedTVIP")
            pairingStatus = "Televize úspěšně spárována."
        case "CHYBA":
            let reason = fields.dropFirst(2).first ?? ""
            pairingStatus = reason == "kod" ? "Nesprávný nebo prošlý kód." :
                reason == "nesparovano" ? "Televize zatím není spárována s konzolí." :
                "Televize párování odmítla."
        default:
            pairingStatus = "Televize vrátila neznámý stav párování."
        }
    }

    /// Sends one packet and repeats it once a second while the caption is valid,
    /// matching Android's heartbeat. Preview uses the Android layout/edit flag so
    /// Google TV shows it even when HDMI is not the selected input.
    func sendSubtitle(_ subtitle: String, duration: Int, preview: Bool = false) {
        repeatTask?.cancel()
        let target = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            message = "Nejprve vyber televizi nebo zadej její IP."
            return
        }
        UserDefaults.standard.set(target, forKey: "tvIP")
        sequence += 1
        let clean = subtitle.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "\\n")
        // Same 5 layout fields as Android: center X, bottom Y, width,
        // font size, and 1 while previewing the position.
        let prefs = UserDefaults.standard
        let x = (prefs.object(forKey: "outputX") as? Double) ?? 0.5
        let y = (prefs.object(forKey: "outputBottom") as? Double) ?? 0.93
        let width = (prefs.object(forKey: "outputWidth") as? Double) ?? 0.62
        let font = (prefs.object(forKey: "outputFont") as? Double) ?? 1.0
        let layout = "\t\(x)\t\(y)\t\(width)\t\(font)\t\(preview ? 1 : 0)"
        let payload = Data("PCT1\t\(sequence)\t\(max(0, duration))\t\(clean)\t\(layout)".utf8)
        sendDatagram(payload, to: target, reportStatus: true)
        guard duration > 0 else { return }
        repeatTask = Task { [weak self] in
            let expiry = Date().addingTimeInterval(Double(duration) / 1000.0)
            while !Task.isCancelled && Date() < expiry {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, Date() < expiry else { break }
                self?.sendDatagram(payload, to: target, reportStatus: false)
            }
        }
    }

    /// Blue dashed OCR region preview, supported by official Android TV receiver.
    /// Coordinates are left, top, right, bottom in a top-left normalized frame.
    func showOCRRegion(_ area: CGRect, visible: Bool) {
        let target = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            message = "Nejprve vyber televizi."
            return
        }
        let packet = "PCO1\t\(visible ? 1 : 0)\t\(area.minX)\t\(area.minY)\t\(area.maxX)\t\(area.maxY)"
        sendDatagram(Data(packet.utf8), to: target, reportStatus: false)
    }

    private var choicesSequence: UInt64 {
        // Choices are delivered through their own sequence counter in Android.
        sequence += 1
        return sequence
    }

    /// PCV1 is accepted by the original PlayCaption TV receiver. No guessed
    /// selected option: -1 is neutral until highlight detection is implemented.
    /// A selected value of -2 signals the Android "Text" (letter/SMS) mode.
    func sendChoices(_ items: [String], area: CGRect,
                     asText: Bool = false,
                     showFrame: Bool = false) {
        let target = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        let escaped = items.joined(separator: "\n")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "\\n")
        let frameFlag = showFrame ? 1 : 0
        let chosen = asText ? -2 : -1
        let packet = "PCV1\t\(choicesSequence)\t\(frameFlag)\t\(area.minX)\t\(area.minY)\t\(area.maxX)\t\(area.maxY)\t\(chosen)\t\(escaped)"
        sendDatagram(Data(packet.utf8), to: target, reportStatus: false)
    }

    private func sendDatagram(_ payload: Data, to target: String, reportStatus: Bool) {
        let connection = NWConnection(host: NWEndpoint.Host(target),
                                      port: NWEndpoint.Port(rawValue: 41989)!,
                                      using: .udp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if reportStatus {
                        Task { @MainActor in
                            self?.message = error == nil
                                ? "Odesláno do \(target). Zobrazení potvrdí až televize."
                                : "Chyba odeslání: \(error!.localizedDescription)"
                        }
                    }
                    connection.cancel()
                })
            case .failed(let error):
                if reportStatus {
                    Task { @MainActor in self?.message = "Nelze odeslat: \(error.localizedDescription)" }
                }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }
}
