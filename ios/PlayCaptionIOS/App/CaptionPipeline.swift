import Foundation
import CoreVideo
import Vision

/// OCR spodní třetiny obrazu. Nový titulek se pošle jen když se text změnil.
actor CaptionPipeline {
    private var lastText = ""
    private var lastRead = Date.distantPast
    private var lastTranslate = [String: String]()

    func recognize(_ buffer: CVPixelBuffer) -> String? {
        // Udržet OCR přibližně 2× za sekundu, ne pro každý WebRTC snímek.
        guard Date().timeIntervalSince(lastRead) > 0.6 else { return nil }
        lastRead = Date()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.regionOfInterest = CGRect(x: 0.04, y: 0.03, width: 0.92, height: 0.34)
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 4, text != lastText,
                  text.filter({ $0.isLetter }).count >= 3 else { return nil }
            lastText = text
            return text
        } catch {
            return nil
        }
    }

    func translate(_ english: String) async -> String {
        if let cached = lastTranslate[english] { return cached }
        // Stejná online strategie jako Android PlayCaption. Neoficiální rozhraní:
        // může být omezené; při chybě vrátíme originál místo prázdného titulku.
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
