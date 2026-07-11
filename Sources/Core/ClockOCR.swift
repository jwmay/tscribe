import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// Reads the burned-in on-screen clock from a video frame, for the "Actual Time"
/// feature. 100% on-device (Vision is an Apple system framework — no network), so
/// it's safe in the Complete edition. OCR only *suggests* a time; the user always
/// confirms or corrects it in the sheet before it's applied.
enum ClockOCR {
    struct Reading {
        var frame: CGImage
        /// Seconds since midnight parsed from the frame's most time-like text, if any.
        var detectedSeconds: TimeInterval?
        /// The raw matched text (shown so the user can sanity-check the OCR).
        var detectedText: String?
    }

    /// Extract the frame at `mediaTime` and OCR it for a clock.
    static func read(media url: URL, at mediaTime: TimeInterval) async throws -> Reading {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let cm = CMTime(seconds: mediaTime, preferredTimescale: 600)
        let frame = try await gen.image(at: cm).image

        let texts = try recognizeText(in: frame)
        for text in texts {
            if let secs = parseTime(text.string) {
                return Reading(frame: frame, detectedSeconds: secs, detectedText: text.string)
            }
        }
        return Reading(frame: frame, detectedSeconds: nil, detectedText: nil)
    }

    private struct Candidate { var string: String; var confidence: Float }

    private static func recognizeText(in image: CGImage) throws -> [Candidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // clocks are digits, not words
        try VNImageRequestHandler(cgImage: image).perform([request])
        let candidates = (request.results ?? []).compactMap { obs -> Candidate? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return Candidate(string: top.string, confidence: top.confidence)
        }
        // Highest-confidence text first, so a crisp clock chip beats blurry captions.
        return candidates.sorted { $0.confidence > $1.confidence }
    }

    /// Parse a wall-clock time out of arbitrary text (an OCR line or the sheet's
    /// text field) into seconds since midnight. Accepts `HH:MM:SS`, `H:MM`,
    /// `.`-separated variants (common OCR misread of `:`), and an AM/PM suffix.
    static func parseTime(_ text: String) -> TimeInterval? {
        // HH:MM(:SS)? with optional AM/PM. Anchored to word-ish boundaries so a
        // date like 12/11/2002 doesn't match.
        let pattern = #"(?<![\d.:])(\d{1,2})[:.](\d{2})(?:[:.](\d{2}))?(?:\s*([AaPp])\.?[Mm]\.?)?(?![\d])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)

        var best: (secs: TimeInterval, hasSeconds: Bool)?
        re.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m else { return }
            func group(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            guard let h = Int(group(1) ?? ""), let min = Int(group(2) ?? "") else { return }
            let sec = Int(group(3) ?? "")
            let ampm = group(4)?.lowercased()
            guard (0...23).contains(h), (0...59).contains(min), (0...59).contains(sec ?? 0) else { return }
            var hour = h
            if let ampm {
                guard (1...12).contains(h) else { return }
                if ampm == "p" && h != 12 { hour = h + 12 }
                if ampm == "a" && h == 12 { hour = 0 }
            }
            let total = TimeInterval(hour * 3600 + min * 60 + (sec ?? 0))
            let hasSeconds = sec != nil
            // Prefer a match that includes seconds (a real clock) over HH:MM noise.
            if best == nil || (hasSeconds && !best!.hasSeconds) {
                best = (total, hasSeconds)
            }
        }
        return best?.secs
    }
}
