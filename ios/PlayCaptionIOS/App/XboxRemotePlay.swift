import Foundation
import WebRTC
import CoreVideo

/// Receiver-only Xbox xHome Remote Play. The player uses the real Xbox over HDMI;
/// we only decode occasional video frames to read English subtitles.
final class XboxRemotePlay: NSObject {
    var onStatus: ((String) -> Void)?
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let authorization: XboxAuthorization
    private var access: XboxStreamingAccess?
    private var sessionURL: String?
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var channels: [String: RTCDataChannel] = [:]
    private let videoSink = XboxVideoSink()
    private let lock = NSLock()
    private var candidates: [RTCIceCandidate] = []
    private var ended = false
    private var lastKeyframe = Date.distantPast
    private var lastFrame = Date.distantPast
    private var heartbeat: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?

    init(authorization: XboxAuthorization) {
        self.authorization = authorization
        super.init()
        videoSink.onPixelBuffer = { [weak self] buffer in
            guard let self else { return }
            self.lastFrame = Date()
            self.onFrame?(buffer)
        }
    }

    private func info(_ message: String) {
        onStatus?(message)
    }

    func connect(console: XboxConsole) async throws {
        info("Přihlašuji Xbox…")
        let access = try await authorization.streamingAccess()
        self.access = access
        if ended { return }
        let headers = await authorization.streamHeaders(access)
        let session = try await authorization.request(
            "\(access.baseURL)/v5/sessions/home/play",
            method: "POST",
            json: ["clientSessionId": "", "titleId": "", "systemUpdateGroup": "",
                   "settings": ["nanoVersion": "V3;WebrtcTransport.dll",
                                "enableTextToSpeech": false, "highContrast": 0,
                                "locale": "en-US", "useIceConnection": false,
                                "timezoneOffsetMinutes": 60, "sdkType": "web", "osName": "android"]],
            headers: headers)
        guard let path = session["sessionPath"] as? String else {
            throw XboxError.message("Xbox nevrátil sessionPath")
        }
        sessionURL = path.hasPrefix("https://") ? path :
            "\(access.baseURL)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        try await waitUntilReady()
        if ended { return }
        info("Navazuji WebRTC spojení…")
        try initializePeer()
        guard let peer else { throw XboxError.message("WebRTC není inicializované") }
        let offer = try await createOffer(peer)
        try await setLocal(offer, on: peer)
        let sdpRequest: [String: Any] = [
            "messageType": "offer", "sdp": offer.sdp,
            "configuration": [
                "chatConfiguration": [
                    "bytesPerSample": 2, "expectedClipDurationMs": 20,
                    "format": ["codec": "opus", "container": "webm"],
                    "numChannels": 1, "sampleFrequencyHz": 24000
                ],
                "chat": ["minVersion": 1, "maxVersion": 1],
                "control": ["minVersion": 1, "maxVersion": 3],
                "input": ["minVersion": 1, "maxVersion": 8],
                "message": ["minVersion": 1, "maxVersion": 1]
            ]
        ]
        _ = try await sessionRequest("sdp", method: "POST", json: sdpRequest)
        let remoteSDP = try await waitForExchange("sdp")
        guard let sdp = remoteSDP["sdp"] as? String else {
            throw XboxError.message("Xbox nevrátil SDP odpověď")
        }
        try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp), on: peer)

        // Give ICE gatherer the same initial window as the Android reference.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        if ended { return }
        lock.lock()
        let offeredCandidates = candidates
        lock.unlock()
        let local: [[String: Any]] = offeredCandidates.map {
            ["candidate": $0.sdp,
             "sdpMLineIndex": Int($0.sdpMLineIndex),
             "sdpMid": $0.sdpMid ?? "0"]
        }
        _ = try await sessionRequest("ice", method: "POST", json: [
            "messageType": "iceCandidate", "candidate": local
        ])
        let remote = try await waitForExchangeArray("ice")
        for item in remote {
            guard let text = item["candidate"] as? String,
                  !text.isEmpty, text != "a=end-of-candidates" else { continue }
            let mid = item["sdpMid"] as? String ?? "0"
            let index = Int32((item["sdpMLineIndex"] as? Int) ??
                Int(item["sdpMLineIndex"] as? String ?? "0") ?? 0)
            peer.add(RTCIceCandidate(sdp: text, sdpMLineIndex: index, sdpMid: mid))
        }
        info("WebRTC navázáno · čekám na obraz")
        keepalive = Task { [weak self] in
            while let self, !Task.isCancelled, !self.ended {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !self.ended, !Task.isCancelled else { break }
                _ = try? await self.sessionRequest("keepalive", method: "POST", json: [:])
            }
        }
        heartbeat = Task { [weak self] in
            while let self, !Task.isCancelled, !self.ended {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !self.ended, !Task.isCancelled else { break }
                // Xbox needs ongoing client activity even when reading only subtitles.
                if Date().timeIntervalSince(self.lastKeyframe) > 4.5 {
                    self.requestKeyframe()
                }
            }
        }
    }

    private func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(90)
        var transferDone = false
        while !ended, Date() < deadline {
            let json = try await sessionRequest("state")
            let state = json["state"] as? String ?? ""
            if state == "Provisioned" { return }
            if state == "ReadyToConnect" && !transferDone {
                transferDone = true
                let token = try await authorization.transferToken()
                _ = try await sessionRequest("connect", method: "POST", json: ["userToken": token])
            }
            if state == "Failed" {
                throw XboxError.message("Xbox zamítl Remote Play: \(json)")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if ended { return }
        throw XboxError.message("Xbox neodpověděl do 90 sekund")
    }

    private func sessionRequest(_ path: String,
                                method: String = "GET",
                                json: [String: Any]? = nil) async throws -> [String: Any] {
        guard let sessionURL, let access else { throw XboxError.message("Chybí relace Xbox") }
        return try await authorization.request(
            "\(sessionURL)/\(path)", method: method, json: json,
            headers: await authorization.streamHeaders(access))
    }

    private func waitForExchange(_ name: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(30)
        while !ended, Date() < deadline {
            let result = try await sessionRequest(name)
            if let string = result["exchangeResponse"] as? String, !string.isEmpty,
               let data = string.data(using: .utf8),
               let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return decoded
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        throw XboxError.message("Xbox nevrátil \(name) zprávu")
    }

    private func waitForExchangeArray(_ name: String) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(30)
        while !ended, Date() < deadline {
            let result = try await sessionRequest(name)
            if let string = result["exchangeResponse"] as? String, !string.isEmpty,
               let data = string.data(using: .utf8),
               let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                return decoded
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        throw XboxError.message("Xbox nevrátil ICE kandidáty")
    }

    private func initializePeer() throws {
        RTCPeerConnectionFactory.initialize()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.candidateNetworkPolicy = .lowCost
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let factory, let peer = factory.peerConnection(
            with: config, constraints: constraints, delegate: self) as RTCPeerConnection? else {
            throw XboxError.message("Vytvoření WebRTC spojení selhalo")
        }
        self.peer = peer
        for (name, proto) in [("chat", "chatV1"), ("control", "controlV1"),
                              ("input", "1.0"), ("message", "messageV1")] {
            let config = RTCDataChannelConfiguration()
            config.isOrdered = true
            config.protocol = proto
            if let channel = peer.dataChannel(forLabel: name, configuration: config) {
                channels[name] = channel
                channel.delegate = self
            }
        }
        let audio = RTCRtpTransceiverInit()
        audio.direction = .sendRecv
        _ = peer.addTransceiver(of: .audio, init: audio)
        let video = RTCRtpTransceiverInit()
        video.direction = .recvOnly
        _ = peer.addTransceiver(of: .video, init: video)
    }

    private func createOffer(_ peer: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
                optionalConstraints: nil)
            peer.offer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else {
                    continuation.resume(throwing: XboxError.message("WebRTC nevytvořilo nabídku"))
                    return
                }
                continuation.resume(returning: RTCSessionDescription(
                    type: sdp.type, sdp: self.preferH264(sdp.sdp)))
            }
        }
    }

    private func setLocal(_ sdp: RTCSessionDescription, on peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(sdp) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    private func setRemote(_ sdp: RTCSessionDescription, on peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(sdp) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    private func preferH264(_ sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        guard let videoIndex = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return sdp }
        var parts = lines[videoIndex].components(separatedBy: " ")
        guard parts.count > 3 else { return sdp }
        let codecs = Array(parts.dropFirst(3))
        let sorted = codecs.sorted { a, b in
            func weight(_ id: String) -> Int {
                guard let spec = lines.first(where: { $0.hasPrefix("a=rtpmap:\(id) ") }) else { return 9 }
                return spec.localizedCaseInsensitiveContains("H264") ? 0 : 5
            }
            return weight(a) < weight(b)
        }
        parts = Array(parts.prefix(3)) + sorted
        lines[videoIndex] = parts.joined(separator: " ")
        return lines.joined(separator: "\r\n")
    }

    private func send(_ channelName: String, _ payload: [String: Any]) {
        guard let channel = channels[channelName], channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    private func requestKeyframe() {
        lastKeyframe = Date()
        send("control", ["message": "videoKeyframeRequested", "ifrRequested": true])
    }

    private func configureStream() {
        func message(_ target: String, _ content: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: content),
                  let string = String(data: data, encoding: .utf8) else { return }
            send("message", [
                "type": "Message", "content": string,
                "id": UUID().uuidString, "target": target, "cv": ""
            ])
        }
        message("/streaming/systemUi/configuration", ["version": [0, 2, 0], "systemUis": []])
        message("/streaming/properties/clientappinstallidchanged", ["clientAppInstallId": UUID().uuidString])
        message("/streaming/characteristics/orientationchanged", ["orientation": 0])
        message("/streaming/characteristics/touchinputenabledchanged", ["touchInputEnabled": false])
        message("/streaming/characteristics/clientdevicecapabilities", [:])
        message("/streaming/characteristics/dimensionschanged", [
            "horizontal": 1280, "vertical": 720, "preferredWidth": 1280, "preferredHeight": 720,
            "safeAreaLeft": 0, "safeAreaTop": 0, "safeAreaRight": 1280, "safeAreaBottom": 720,
            "supportsCustomResolution": true
        ])
    }

    private func handshakeAcknowledged() {
        info("Xbox handshake OK")
        send("control", ["message": "authorizationRequest",
                         "accessKey": "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"])
        send("control", ["message": "gamepadChanged", "gamepadIndex": 0, "wasAdded": true])
        send("control", ["message": "gamepadChanged", "gamepadIndex": 0, "wasAdded": false])
        var bytes = Data()
        var first = UInt16(8).littleEndian
        var second = UInt32(0).littleEndian
        var time = (ProcessInfo.processInfo.systemUptime * 1000).bitPattern.littleEndian
        withUnsafeBytes(of: &first) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: &second) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: &time) { bytes.append(contentsOf: $0) }
        bytes.append(1)
        if let channel = channels["input"], channel.readyState == .open {
            _ = channel.sendData(RTCDataBuffer(data: bytes, isBinary: true))
        }
        configureStream()
        requestKeyframe()
    }

    func stop() {
        if ended { return }
        ended = true
        keepalive?.cancel()
        heartbeat?.cancel()
        let session = sessionURL
        let access = access
        videoTrack?.remove(videoSink)
        peer?.close()
        channels.removeAll()
        peer = nil
        factory = nil
        if let session, let access {
            Task {
                _ = try? await authorization.request(
                    session, method: "DELETE",
                    headers: await authorization.streamHeaders(access))
            }
        }
        info("Remote Play zastaveno")
    }
}

private final class XboxVideoSink: NSObject, RTCVideoRenderer {
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?
    private var lastSent: TimeInterval = 0

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame,
              let buffer = frame.buffer as? RTCCVPixelBuffer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSent > 0.55 else { return }
        lastSent = now
        onPixelBuffer?(buffer.pixelBuffer)
    }
}

extension XboxRemotePlay: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        info("ICE: \(newState.rawValue)")
        if newState == .failed { info("ICE selhalo, ověř síť a NAT") }
        if newState == .disconnected { info("ICE odpojeno") }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock()
        candidates.append(candidate)
        lock.unlock()
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let video = transceiver.receiver.track as? RTCVideoTrack {
            videoTrack = video
            video.add(videoSink)
            info("Xbox video stopa připojena")
        }
        if let audio = transceiver.receiver.track as? RTCAudioTrack {
            audio.isEnabled = false
        }
    }
}

extension XboxRemotePlay: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.label == "message", dataChannel.readyState == .open {
            send("message", ["type": "Handshake", "version": "messageV1",
                             "id": UUID().uuidString, "cv": "0"])
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel.label == "message",
              let payload = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
              let type = payload["type"] as? String else { return }
        if type == "HandshakeAck" {
            handshakeAcknowledged()
        } else if type == "TransactionStart" || type == "Message" {
            let target = payload["target"] as? String ?? ""
            if target.hasSuffix("serverInitiatedDisconnect") {
                info("Xbox ukončil Remote Play (serverInitiatedDisconnect)")
                stop()
            }
        }
    }
}
