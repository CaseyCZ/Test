import Foundation
import CoreVideo
import Vision

/// Vision coordinates start at bottom-left. Constrain OCR to subtitle bands
/// rather than all the labels, map controls and HUD in the game image.
enum SubtitleRegion: String, CaseIterable, Identifiable {
    case narrow
    case center
    case wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .narrow: return "Úzká – pouze titulky"
        case .center: return "Střed – doporučeno"
        case .wide: return "Široká – původní"
        }
    }

    var rect: CGRect {
        switch self {
        case .narrow:
            return CGRect(x: 0.23, y: 0.10, width: 0.54, height: 0.17)
        case .center:
            return CGRect(x: 0.15, y: 0.07, width: 0.70, height: 0.23)
        case .wide:
            return CGRect(x: 0.04, y: 0.03, width: 0.92, height: 0.34)
        }
    }
}

/// OCR speed presets. The verified legacy path remains the default.
enum OCRMode: String, CaseIterable, Identifiable {
    case classic
    case automatic
    case street

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Původní · stabilní"
        case .automatic: return "Automatický · vyvážený"
        case .street: return "Krátké dialogy · rychlý"
        }
    }

    var explanation: String {
        switch self {
        case .classic: return "Původní čtení přibližně každých 0,6 sekundy. Výchozí pro zachování funkčního chování."
        case .automatic: return "Častější snímání a šetrnější filtr krátkých herních vět."
        case .street: return "Zachytává i velmi krátké věty. Vyšší náročnost na baterii a výkon iPhonu."
        }
    }

    var minimumOCRInterval: TimeInterval {
        switch self {
        case .classic: return 0.6
        case .automatic: return 0.42
        case .street: return 0.28
        }
    }

    var minimumFrameInterval: TimeInterval {
        switch self {
        case .classic: return 0.55
        case .automatic: return 0.37
        case .street: return 0.26
        }
    }
}

struct RecognizedCaption {
    let english: String
    let revision: Int
    let capturedAt: Date
}

/// OCR of a configurable bottom-center band. Only changed subtitle text is sent.
actor CaptionPipeline {
    private var lastText = ""
    private var lastRead = Date.distantPast
    private var lastSeen = Date.distantPast
    private var lastTranslate = [String: String]()
    private var lastSettings = ""
    private var emptyReads = 0
    private var revision = 0

    // Text painted onto a moving car may enter the subtitle ROI. Match the
    // screen-space position and content across successive OCR frames before
    // treating a candidate as dialogue. Never share this state with choices.
    private var pendingDialogue = ""
    private var pendingBounds: CGRect = .zero
    private var pendingHits = 0
    private var pendingAt = Date.distantPast

    private func resetCandidate() {
        pendingDialogue = ""
        pendingBounds = .zero
        pendingHits = 0
        pendingAt = .distantPast
    }

    func resetDialogue() {
        lastText = ""
        lastRead = .distantPast
        lastSeen = .distantPast
        lastSettings = ""
        emptyReads = 0
        resetCandidate()
        revision += 1
    }

    func isCurrent(revision candidate: Int) -> Bool {
        revision == candidate
    }

    func recognize(_ buffer: CVPixelBuffer,
                   region: SubtitleRegion,
                   manualArea: CGRect?,
                   filterMenus: Bool,
                   mode: OCRMode = .classic,
                   expandOnEmpty: Bool = false,
                   dialogueGuard: Bool = true) -> RecognizedCaption? {
        let baseROI = manualArea.map { CGRect(
            x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height
        ) } ?? region.rect
        let settings = "\(baseROI)|\(filterMenus)|\(mode.rawValue)|\(expandOnEmpty)|\(dialogueGuard)"
        if settings != lastSettings {
            lastSettings = settings
            lastText = ""
            lastRead = .distantPast
            lastSeen = .distantPast
            emptyReads = 0
            resetCandidate()
            revision += 1
        }

        let now = Date()
        guard now.timeIntervalSince(lastRead) > mode.minimumOCRInterval else { return nil }
        lastRead = now

        // Optional low-frequency fallback. It NEVER overrides manually selected OCR.
        let searchWide = expandOnEmpty && manualArea == nil &&
            mode != .classic && emptyReads >= 3 && emptyReads % 3 == 0
        let roi = searchWide ? SubtitleRegion.wide.rect : baseROI
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.regionOfInterest = roi

        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
            let minLetters = mode == .street ? 2 : 3
            let candidates = (request.results ?? []).compactMap { item -> (text: String, box: CGRect)? in
                guard let recognized = item.topCandidates(1).first else { return nil }
                let line = recognized.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.filter({ $0.isLetter }).count >= minLetters else { return nil }
                if filterMenus && looksLikeMenu(line, conservative: mode != .classic) {
                    return nil
                }
                // Logos on cars can stay fixed on screen with a chase camera.
                // In guarded mode, avoid translating isolated names/brands even
                // if they happen to sit exactly inside the subtitle rectangle.
                if dialogueGuard && looksLikeSceneLabel(line) { return nil }
                return (line, item.boundingBox)
            }

            // The unfiltered mode preserves original behavior for fast/short
            // dialogue and games whose subtitles are not centered.
            let selected: [(text: String, box: CGRect)]
            if dialogueGuard {
                let centered = candidates.filter { abs($0.box.midX - 0.5) < 0.35 }
                    .sorted { $0.box.midY < $1.box.midY }
                // Choose the lowest screen-centered subtitle and nearby stacked
                // lines. Do not concatenate unrelated car decals/HUD labels.
                if let bottom = centered.first {
                    selected = centered.filter {
                        abs($0.box.midY - bottom.box.midY) < 0.085 &&
                        abs($0.box.midX - bottom.box.midX) < 0.23
                    }.sorted { $0.box.midY > $1.box.midY }
                } else {
                    selected = []
                }
            } else {
                selected = candidates
            }
            let text = selected.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= (mode == .street ? 2 : 4),
                  text.filter({ $0.isLetter }).count >= minLetters else {
                emptyReads += 1
                if now.timeIntervalSince(pendingAt) > 1.6 { resetCandidate() }
                // A repeated greeting must be eligible again after it disappears.
                if !lastText.isEmpty && now.timeIntervalSince(lastSeen) > 1.0 {
                    lastText = ""
                }
                return nil
            }

            // Ignore text that moves through the subtitle band with the scene.
            // A stable screen overlay will appear at nearly the same bounds
            // for two samples; a single unpunctuated label needs three.
            if dialogueGuard, let anchor = selected.last?.box {
                let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber }
                let compatible = normalized == pendingDialogue &&
                    now.timeIntervalSince(pendingAt) < 1.6 &&
                    abs(anchor.midX - pendingBounds.midX) < 0.035 &&
                    abs(anchor.midY - pendingBounds.midY) < 0.025
                pendingHits = compatible ? pendingHits + 1 : 1
                pendingDialogue = normalized
                pendingBounds = anchor
                pendingAt = now
                let words = text.split(whereSeparator: { $0.isWhitespace })
                let weakSingleLabel = words.count == 1 &&
                    !text.contains(where: { ".!?,:;".contains($0) })
                guard pendingHits >= (weakSingleLabel ? 3 : 2) else { return nil }
            } else {
                resetCandidate()
            }

            lastSeen = now
            emptyReads = 0
            guard text != lastText else { return nil }
            lastText = text
            revision += 1
            return RecognizedCaption(english: text, revision: revision, capturedAt: now)
        } catch {
            return nil
        }
    }

    // Dedicated OCR lane for the optional Android-style yellow response area.
    // It never changes the standard dialogue OCR region.
    private var lastOptions = [String]()
    private var lastOptionsRead = Date.distantPast
    private var lastOptionsSettings = ""

    func resetOptions() {
        lastOptions = []
        lastOptionsRead = .distantPast
        lastOptionsSettings = ""
    }

    /// The area uses top-left normalized screen coordinates, unlike Vision.
    /// Returns nil when unchanged; [] when choices disappeared and TV should clear.
    func recognizeOptions(_ buffer: CVPixelBuffer,
                          area: CGRect,
                          asText: Bool) -> [String]? {
        let signature = "\(area)|\(asText)"
        if signature != lastOptionsSettings {
            lastOptionsSettings = signature
            lastOptions = []
            lastOptionsRead = .distantPast
        }
        guard Date().timeIntervalSince(lastOptionsRead) > 1.0 else { return nil }
        lastOptionsRead = Date()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.regionOfInterest = CGRect(x: area.minX,
                                           y: 1 - area.maxY,
                                           width: area.width, height: area.height)
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
            let lines = (request.results ?? [])
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.filter { $0.isLetter }.count >= 3 }

            let output = asText
                ? (lines.isEmpty ? [] : [lines.joined(separator: " ")])
                : Array(lines.prefix(6))
            guard output != lastOptions else { return nil }
            lastOptions = output
            return output
        } catch {
            return nil
        }
    }

    /// Reject likely car brands, license plate fragments and scene labels.
    /// This is deliberately optional: one-word dialogue and title-case
    /// greetings may be indistinguishable without audio or game semantics.
    private func looksLikeSceneLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return true }
        // Natural utterances with punctuation should not be discarded.
        if text.contains(where: { ".!?,:;…".contains($0) }) { return false }

        let spokenSingleWords: Set<String> = [
            "yes", "no", "yeah", "yep", "nope", "hey", "hi", "hello",
            "wait", "stop", "help", "go", "run", "thanks", "sorry",
            "please", "okay", "ok", "what", "why", "who", "where",
            "shit", "damn", "right", "fine", "sure", "come", "look"
        ]
        let spokenShortPhrases: Set<String> = [
            "thank you", "good morning", "good night", "come on",
            "watch out", "get out", "oh no", "all right", "let's go"
        ]
        let normalized = text.lowercased()
        if words.count == 1 {
            return !spokenSingleWords.contains(normalized)
        }
        if spokenShortPhrases.contains(normalized) { return false }
        guard words.count <= 3 else { return false }

        // "Vapid Dominator", "Karin Futo", "FORD MUSTANG" etc. are much
        // likelier to be a name than a subtitle in normal sentence case.
        let titleOrCaps = words.allSatisfy { word in
            let letters = word.filter { $0.isLetter }
            guard let first = letters.first, first.isUppercase else { return false }
            return letters.dropFirst().allSatisfy { $0.isLowercase } ||
                letters.allSatisfy { $0.isUppercase }
        }
        return titleOrCaps
    }

    /// Conservative, optional filter for many uppercase short menu labels.
    /// Not perfect: all-uppercase in-game dialogue can be excluded; users can
    /// switch the filter off without affecting the Remote Play session.
    private func looksLikeMenu(_ text: String, conservative: Bool) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return true }
        let upperWords = words.filter { word in
            let letters = word.filter { $0.isLetter }
            return letters.count >= 3 && letters.allSatisfy { $0.isUppercase }
        }.count
        let punctuation = text.contains { ".!?;:".contains($0) }
        if punctuation { return false }

        if conservative {
            // A short all-caps greeting ("HEY", "HELP") is not automatically a menu.
            let normalized = text.uppercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let menus: Set<String> = [
                "PAUSE", "OPTIONS", "SETTINGS", "NEW GAME", "LOAD GAME",
                "SAVE GAME", "INVENTORY", "QUEST LOG", "MAP", "EXIT",
                "CONTINUE", "RESTART", "GAME OVER", "OBJECTIVES", "SKIP"
            ]
            return menus.contains(normalized) || (words.count >= 4 && upperWords >= 4)
        }
        if words.count <= 3 && upperWords >= 1 { return true }
        return words.count >= 4 && upperWords >= 3
    }

    func translate(_ english: String) async -> String {
        if let cached = lastTranslate[english] { return cached }
        // Same online strategy as the reference Android PlayCaption. Unofficial endpoint.
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "en"),
            URLQueryItem(name: "tl", value: "cs"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: english)
        ]
        guard let url = components?.url else { return english }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let array = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let segments = array.first as? [[Any]] else { return english }
            let czech = segments.compactMap { $0.first as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !czech.isEmpty else { return english }
            if lastTranslate.count > 250 { lastTranslate.removeAll() }
            lastTranslate[english] = czech
            return czech
        } catch {
            return english
        }
    }
}
