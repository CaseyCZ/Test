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

/// OCR of a configurable bottom-center band. Only changed subtitle text is sent.
actor CaptionPipeline {
    private var lastText = ""
    private var lastRead = Date.distantPast
    private var lastTranslate = [String: String]()
    private var lastSettings = ""

    func recognize(_ buffer: CVPixelBuffer,
                   region: SubtitleRegion,
                   filterMenus: Bool) -> String? {
        let settings = "\(region.rawValue)|\(filterMenus)"
        if settings != lastSettings {
            lastSettings = settings
            lastText = ""
            lastRead = .distantPast
        }

        // Around 1.5 OCR reads per second to avoid overloading the phone.
        guard Date().timeIntervalSince(lastRead) > 0.6 else { return nil }
        lastRead = Date()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.regionOfInterest = region.rect

        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { item -> String? in
                guard let candidate = item.topCandidates(1).first else { return nil }
                let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.filter({ $0.isLetter }).count >= 3 else { return nil }
                if filterMenus && looksLikeMenu(line) { return nil }
                return line
            }
            let text = lines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 4, text != lastText,
                  text.filter({ $0.isLetter }).count >= 3 else { return nil }
            lastText = text
            return text
        } catch {
            return nil
        }
    }

    /// Conservative, optional filter for many uppercase short menu labels.
    /// Not perfect: all-uppercase in-game dialogue can be excluded; users can
    /// switch the filter off without affecting the Remote Play session.
    private func looksLikeMenu(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return true }
        let upperWords = words.filter { word in
            let letters = word.filter { $0.isLetter }
            return letters.count >= 3 && letters.allSatisfy { $0.isUppercase }
        }.count
        let punctuation = text.contains { ".!?;:".contains($0) }
        if punctuation { return false }
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
