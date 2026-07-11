import Foundation

/// A saved transcript project: the transcript plus a reference back to its media.
struct TranscriptDocument: Codable {
    // v2 adds `Transcript.speakers` + `Segment.speaker` (speaker diarization).
    // v3 adds `Transcript.clockOffset` (Actual Time from the video's on-screen clock).
    // Older files still load — the new fields decode as empty/nil.
    var version = 3
    var mediaFileName: String
    var mediaPath: String
    var mediaBookmark: Data?
    var createdAt: Date
    var transcript: Transcript
}
