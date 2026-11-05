import Foundation
import TranscriptCore
import Vision

/// Reads the text on slide photos (Chinese and English) with Vision.
///
/// Runs on its own serial, low-priority queue, one photo at a time, so taking
/// photos and scrolling never wait for it.
final class SlideTextRecognizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Dictation.slideText", qos: .utility)
    private let log: DiagnosticsLog

    init(log: DiagnosticsLog) {
        self.log = log
    }

    /// The recognized lines joined by newlines, or nil if there's no text.
    func recognizeText(at url: URL) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                continuation.resume(returning: self.recognize(url: url))
            }
        }
    }

    private func recognize(url: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log.log("Slide text recognition failed for \(url.lastPathComponent): \(error)", category: "vision")
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
