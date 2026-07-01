import Foundation

/// A saved transcript project: the transcript plus a reference back to its media.
struct TranscriptDocument: Codable {
    var version = 1
    var mediaFileName: String
    var mediaPath: String
    var mediaBookmark: Data?
    var createdAt: Date
    var transcript: Transcript
}
