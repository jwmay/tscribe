import Foundation

/// A full transcript: an ordered list of timestamped segments, plus an optional
/// roster of identified speakers (populated by the "Identify Speakers" feature).
struct Transcript: Equatable, Codable {
    var segments: [Segment]
    /// Identified speakers, in first-appearance order. Empty when the transcript
    /// has not been diarized. Each `Segment.speaker` references a `Speaker.key`.
    var speakers: [Speaker] = []
    /// Seconds to add to a media time to get the recording's *actual* (wall-clock)
    /// time, anchored from the video's burned-in on-screen clock ("Actual Time"
    /// feature). nil = show media-relative times. Segment/word times themselves
    /// always stay media-relative so playback/seek keep working.
    var clockOffset: TimeInterval? = nil

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// The name to show for a segment's speaker key: the user-given name, or a
    /// generated "Speaker A" fallback, or nil when there's no speaker.
    func displayName(forSpeaker key: String?) -> String? {
        guard let key else { return nil }
        return speakers.first(where: { $0.key == key })?.displayName ?? "Speaker \(key)"
    }

    /// The timestamp to show/export for a media time: the recording's actual
    /// clock time when an offset is set, otherwise the media-relative time.
    func timecode(_ t: TimeInterval) -> String {
        guard let off = clockOffset else { return Timecode.hms(t) }
        return Timecode.wall(t + off)
    }

    /// Segments matching a search query and/or speaker filter (both optional,
    /// combined with AND). The query matches segment text case-insensitively,
    /// and also the speaker's display name — so searching "Shapiro" finds every
    /// line spoken by a named speaker.
    func filteredSegments(query: String, speaker: String?) -> [Segment] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return segments.filter { seg in
            if let speaker, seg.speaker != speaker { return false }
            if q.isEmpty { return true }
            if seg.text.localizedCaseInsensitiveContains(q) { return true }
            if let name = displayName(forSpeaker: seg.speaker),
               name.localizedCaseInsensitiveContains(q) { return true }
            return false
        }
    }

    // Decode tolerantly so older `.tscribe` files — which lack the `speakers` /
    // `clockOffset` keys — still load. (Synthesized Decodable would require them.)
    private enum CodingKeys: String, CodingKey { case segments, speakers, clockOffset }
}

extension Transcript {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decode([Segment].self, forKey: .segments)
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        clockOffset = try c.decodeIfPresent(TimeInterval.self, forKey: .clockOffset)
    }
}

/// One identified speaker. `key` is a stable, persisted label ("A", "B", …) that
/// segments reference; `name` is the (optionally user-edited) display name.
struct Speaker: Identifiable, Equatable, Codable {
    var key: String
    var name: String = ""

    var id: String { key }
    /// User-given name, or a generated fallback when unnamed.
    var displayName: String { name.isEmpty ? "Speaker \(key)" : name }
}

/// One spoken segment (roughly a sentence/phrase) with word-level detail.
struct Segment: Identifiable, Equatable, Codable {
    let id = UUID()
    var start: TimeInterval   // seconds
    var end: TimeInterval     // seconds
    var text: String
    var words: [Word]
    /// Speaker key (references `Transcript.speakers`), or nil when not diarized.
    var speaker: String? = nil

    /// Lowest word confidence in the segment (0...1) — a quick "needs review" signal.
    var minConfidence: Double { words.map(\.confidence).min() ?? 1 }

    private enum CodingKeys: String, CodingKey { case start, end, text, words, speaker }
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
