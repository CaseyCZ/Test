import Foundation
import Network
import Combine

import CryptoKit
import Security

private enum ReceiverSecretStore {
    static func account(_ ip: String) -> String { "iphone-tv-" + ip }

    static func load(_ ip: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cz.caseycz.playcaption.tvpairing",
            kSecAttrAccount as String: account(ip),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &value)
        guard code == errSecSuccess, let data = value as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    static func save(_ token: String, ip: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cz.caseycz.playcaption.tvpairing",
            kSecAttrAccount as String: account(ip)
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ ip: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cz.caseycz.playcaption.tvpairing",
            kSecAttrAccount as String: account(ip)
        ]
        SecItemDelete(query as CFDictionary)
    }
}


struct PlayCaptionDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var ip: String
}

@MainActor
final class PlayCaptionTV: ObservableObject {
    @Published var ip: String = UserDefaults.standard.string(forKey: "tvIP") ?? "" {
        didSet {
            UserDefaults.standard.set(ip, forKey: "tvIP")
            if oldValue != ip { startReceiverHeartbeat() }
        }
    }
    @Published var receiverCode = ""
    @Published private(set) var receiverStatus = "Televize zatím není spárovaná s iPhonem."
    @Published private(set) var receiverConnected = false
    @Published private(set) var lastCaptionAcknowledgement = ""

    private let receiverID: String = {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "receiverPhoneID") { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: "receiverPhoneID")
        return value
    }()
    private var pairingRequest: NWConnection?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var liveReceiver: NWConnection?
    private var receiverHeartbeatTask: Task<Void, Never>?
    private var liveReceiverReady = false
    private var liveReceiverTarget = ""
    private var lastPong: Date?

    var receiverPaired: Bool {
        ReceiverSecretStore.load(ip.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
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

    init() {
        startReceiverHeartbeat()
    }
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

    // TV pairing is separate from Xbox / Microsoft account sign-in.
    // The PIN is displayed only on our independent TV receiver app.
    func pairReceiver() {
        let target = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = receiverCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, code.count == 6, code.allSatisfy(\.isNumber) else {
            receiverStatus = "Zadej šest číslic z obrazovky TV."
            return
        }
        pairingRequest?.cancel()
        pairingTimeoutTask?.cancel()
        receiverStatus = "Ověřuji kód na televizi…"
        let pairingClientID = receiverID
        let conn = NWConnection(host: .init(target), port: .init(integerLiteral: 41989), using: .udp)
        pairingRequest = conn
        // UDP does not report a missing reply as a connection failure.
        // Always end a stalled request with actionable feedback.
        pairingTimeoutTask = Task { [weak self, weak conn] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let conn,
                  self.pairingRequest === conn else { return }
            self.receiverStatus = "TV neodpověděla do 10 s. Zkontroluj IP TV, povolení Místní síť a příjem UDP 41989 na TV."
            self.pairingRequest = nil
            conn.cancel()
        }
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn else { return }
            switch state {
            case .ready:
                conn.receiveMessage { [weak self] data, _, _, error in
                    Task { @MainActor in
                        guard let self, self.pairingRequest === conn else { return }
                        self.pairingTimeoutTask?.cancel()
                        self.pairingRequest = nil
                        guard let data, let text = String(data: data, encoding: .utf8) else {
                            self.receiverStatus = "TV neodpověděla. Ověř režim S mobilem, IP a síť."
                            conn.cancel()
                            return
                        }
                        let fields = text.components(separatedBy: "\t")
                        if fields.count == 4, fields[0] == "PCPAIR1",
                           fields[1] == "OK", fields[2] == pairingClientID,
                           fields[3].count == 64,
                           fields[3].allSatisfy({ $0.isHexDigit }),
                           ReceiverSecretStore.save(fields[3], ip: target) {
                            self.receiverCode = ""
                            self.receiverStatus = "iPhone úspěšně spárován. Ověřuji spojení…"
                            self.startReceiverHeartbeat()
                        } else if fields.first == "PCPAIR1", fields.dropFirst().first == "ERROR" {
                            self.receiverStatus = "TV odmítla kód. Vytvoř na TV nový šestimístný kód a zadej ho znovu."
                        } else {
                            self.receiverStatus = "TV vrátila neplatnou odpověď."
                        }
                        conn.cancel()
                    }
                }
                conn.send(content: Data("PCPAIR1\tPAIR\t\(code)\t\(pairingClientID)".utf8),
                          completion: .contentProcessed { [weak self] error in
                    if let error {
                        Task { @MainActor in
                            self?.receiverStatus = "Párování nebylo odesláno: \(error.localizedDescription)"
                        }
                    }
                })
            case .failed(let error):
                Task { @MainActor in
                    guard let self, self.pairingRequest === conn else { return }
                    self.pairingTimeoutTask?.cancel()
                    self.pairingRequest = nil
                    self.receiverStatus = "Spojení s TV selhalo: \(error.localizedDescription)"
                }
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func forgetReceiver() {
        pairingTimeoutTask?.cancel()
        pairingRequest?.cancel()
        pairingRequest = nil
        ReceiverSecretStore.remove(ip.trimmingCharacters(in: .whitespacesAndNewlines))
        receiverCode = ""
        receiverStatus = "Párování na iPhonu zrušeno."
        startReceiverHeartbeat()
    }

    private func signature(_ payload: String, tokenHex: String) -> String? {
        guard tokenHex.count == 64 else { return nil }
        var keyBytes = [UInt8]()
        for offset in stride(from: 0, to: tokenHex.count, by: 2) {
            let a = tokenHex.index(tokenHex.startIndex, offsetBy: offset)
            let b = tokenHex.index(a, offsetBy: 2)
            guard let byte = UInt8(tokenHex[a..<b], radix: 16) else { return nil }
            keyBytes.append(byte)
        }
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8), using: SymmetricKey(data: Data(keyBytes)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func startReceiverHeartbeat() {
        receiverHeartbeatTask?.cancel()
        liveReceiver?.cancel()
        liveReceiver = nil
        liveReceiverReady = false
        receiverConnected = false
        lastPong = nil
        lastCaptionAcknowledgement = ""
        let target = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, ReceiverSecretStore.load(target) != nil else {
            receiverStatus = target.isEmpty ? "Nejdříve vyber televizi." :
                "TV je vybraná. Pro ověřené spojení ji spáruj šestímístným kódem."
            return
        }
        receiverStatus = "Připojuji se ke spárované TV…"
        let conn = NWConnection(host: .init(target), port: .init(integerLiteral: 41989), using: .udp)
        liveReceiver = conn
        liveReceiverTarget = target
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn else { return }
            switch state {
            case .ready:
                Task { @MainActor in
                    guard let self, self.liveReceiver === conn, self.ip == target else { return }
                    self.liveReceiverReady = true
                    self.readReceiverReply(on: conn, target: target)
                    self.receiverHeartbeatTask = Task { [weak self] in
                        while !Task.isCancelled {
                            guard let self, let token = ReceiverSecretStore.load(target),
                                  self.liveReceiver === conn else { break }
                            let nonce = UUID().uuidString
                            let body = "PING\t\(self.receiverID)\t\(nonce)"
                            if let mac = self.signature(body, tokenHex: token) {
                                conn.send(content: Data("PCPAIR1\t\(body)\t\(mac)".utf8),
                                          completion: .contentProcessed { _ in })
                            }
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { break }
                            if let last = self.lastPong, Date().timeIntervalSince(last) < 9 {
                                self.receiverConnected = true
                                self.receiverStatus = "TV spárovaná · spojení aktivní"
                            } else {
                                self.receiverConnected = false
                                self.receiverStatus = "TV spárovaná · čekám na odpověď"
                            }
                        }
                    }
                }
            case .failed(let error):
                Task { @MainActor in
                    guard let self, self.liveReceiver === conn else { return }
                    self.liveReceiverReady = false
                    self.receiverConnected = false
                    self.receiverStatus = "TV neodpovídá: \(error.localizedDescription)"
                }
            case .cancelled:
                Task { @MainActor in
                    if let self, self.liveReceiver === conn { self.liveReceiverReady = false }
                }
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func readReceiverReply(on conn: NWConnection, target: String) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let conn else { return }
            Task { @MainActor in
                guard let self, self.liveReceiver === conn, self.ip == target else { return }
                if let data, let raw = String(data: data, encoding: .utf8) {
                    let fields = raw.components(separatedBy: "\t")
                    if fields.count >= 3 && fields[0] == "PCPAIR1" && fields[1] == "PONG" {
                        self.lastPong = Date()
                        self.receiverConnected = true
                        self.receiverStatus = "TV spárovaná · spojení aktivní"
                    } else if fields.count >= 3 && fields[0] == "PCA1" &&
                                fields[2] == "RECEIVED" {
                        self.lastCaptionAcknowledgement = "Televize potvrdila přijetí titulku."
                        self.message = self.lastCaptionAcknowledgement
                    }
                }
                if error == nil { self.readReceiverReply(on: conn, target: target) }
            }
        }
    }

    /// Authenticated subtitle sent through the verified receiver session.
    /// Original PlayCaption 0.22 still receives regular PCT1 when not paired.
    private func sendSignedSubtitle(_ canonicalPayload: Data, to target: String,
                                    reportStatus: Bool) -> Bool {
        guard let token = ReceiverSecretStore.load(target) else { return false }
        let encoded = canonicalPayload.base64EncodedString()
        let body = "TEXT\t\(receiverID)\t\(encoded)"
        guard let mac = signature(body, tokenHex: token) else { return false }
        let packet = Data("PCPAIR1\t\(body)\t\(mac)".utf8)
        if liveReceiverReady, liveReceiverTarget == target, let conn = liveReceiver {
            conn.send(content: packet, completion: .contentProcessed { [weak self] error in
                if reportStatus {
                    Task { @MainActor in
                        self?.message = error == nil
                            ? "Titulek odeslán. Čekám na potvrzení TV…"
                            : "Chyba odeslání: \(error!.localizedDescription)"
                    }
                }
            })
        } else {
            sendDatagram(packet, to: target, reportStatus: reportStatus)
        }
        return true
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
        // Original PlayCaption 0.22 protocol: field 4 is an empty hint.
        // Without it the TV misreads X/Y/width and draws a huge black strip.
        let fields = [
            "PCT1", String(sequence), String(max(0, duration)),
            clean, "", String(x), String(y), String(width), String(font),
            preview ? "1" : "0"
        ]
        let payload = Data(fields.joined(separator: "\t").utf8)
        if !sendSignedSubtitle(payload, to: target, reportStatus: true) {
            sendDatagram(payload, to: target, reportStatus: true)
        }
        guard duration > 0 else { return }
        repeatTask = Task { [weak self] in
            let expiry = Date().addingTimeInterval(Double(duration) / 1000.0)
            while !Task.isCancelled && Date() < expiry {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, Date() < expiry else { break }
                guard let self else { break }
                if !self.sendSignedSubtitle(payload, to: target, reportStatus: false) {
                    self.sendDatagram(payload, to: target, reportStatus: false)
                }
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
                     showFrame: Bool = false,
                     outputArea: CGRect? = nil,
                     outputFont: Double = 1.0) {
        let target = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        let escaped = items.joined(separator: "\n")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "\\n")
        let frameFlag = showFrame ? 1 : 0
        let chosen = asText ? -2 : -1
        // PCV1 extension: output rectangle and independent game-text font scale.
        // Older PlayCaption receivers ignore additional fields safely.
        let outputSuffix: String
        if let rect = outputArea {
            let scale = outputFont.isFinite ? min(2.0, max(0.6, outputFont)) : 1.0
            outputSuffix = "\t\(rect.minX)\t\(rect.minY)\t\(rect.maxX)\t\(rect.maxY)\t\(scale)"
        } else {
            outputSuffix = ""
        }
        let packet = "PCV1\t\(choicesSequence)\t\(frameFlag)\t\(area.minX)\t\(area.minY)\t\(area.maxX)\t\(area.maxY)\t\(chosen)\t\(escaped)\(outputSuffix)"
        let bytes = Data(packet.utf8)
        if !sendSignedSubtitle(bytes, to: target, reportStatus: false) {
            sendDatagram(bytes, to: target, reportStatus: false)
        }
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
