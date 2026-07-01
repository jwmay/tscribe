import Foundation

/// Reads/writes .tscribe documents and manages the auto-save library
/// (~/Documents/Tscribe), which powers the "Recent transcripts" list.
enum TranscriptStore {
    static let fileExtension = "tscribe"

    static var libraryURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Tscribe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func autosaveURL(forMediaNamed name: String) -> URL {
        libraryURL.appendingPathComponent(name).appendingPathExtension(fileExtension)
    }

    static func save(_ doc: TranscriptDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(doc).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> TranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: url))
    }

    struct RecentItem: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let name: String
        let date: Date
    }

    static func recents(limit: Int = 12) -> [RecentItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == fileExtension }
            .map { url -> RecentItem in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return RecentItem(url: url, name: url.deletingPathExtension().lastPathComponent, date: date)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }
}
