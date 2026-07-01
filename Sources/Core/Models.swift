import Foundation

/// A full transcript: an ordered list of timestamped segments.
struct Transcript: Equatable, Codable {
    var segments: [Segment]

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }
}

/// One spoken segment (roughly a sentence/phrase) with word-level detail.
struct Segment: Identifiable, Equatable, Codable {
    let id = UUID()
    var start: TimeInterval   // seconds
    var end: TimeInterval     // seconds
    var text: String
    var words: [Word]

    /// Lowest word confidence in the segment (0...1) — a quick "needs review" signal.
    var minConfidence: Double { words.map(\.confidence).min() ?? 1 }

    private enum CodingKeys: String, CodingKey { case start, end, text, words }
}

/// One word, aligned to the audio, with a confidence score.
struct Word: Identifiable, Equatable, Codable {
    let id = UUID()
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Double    // 0...1, derived from whisper token probability

    private enum CodingKeys: String, CodingKey { case text, start, end, confidence }
}
