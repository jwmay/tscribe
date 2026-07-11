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

    // MARK: Library-wide search

    /// One saved transcript containing matches for a library search.
    struct LibraryHit: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let name: String
        let date: Date
        let matchCount: Int
        /// First few matching lines, pre-formatted as "timecode — text".
        let snippets: [String]

        static func == (a: LibraryHit, b: LibraryHit) -> Bool {
            a.url == b.url && a.matchCount == b.matchCount
        }
    }

    /// Search every saved transcript for a text query. `urls` overrides the file
    /// list (for tests); by default the whole library is scanned. Unreadable
    /// files are skipped. Hits are sorted by match count, most first.
    static func searchLibrary(query: String,
                              in urls: [URL]? = nil,
                              snippetLimit: Int = 2) -> [LibraryHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let files = urls ?? recents(limit: Int.max).map(\.url)

        var hits: [LibraryHit] = []
        for url in files {
            guard let doc = try? load(from: url) else { continue }
            let matches = doc.transcript.filteredSegments(query: q, speaker: nil)
            guard !matches.isEmpty else { continue }
            let snippets = matches.prefix(snippetLimit).map { seg in
                "\(doc.transcript.timecode(seg.start)) — \(seg.text.count > 90 ? String(seg.text.prefix(90)) + "…" : seg.text)"
            }
            hits.append(LibraryHit(url: url,
                                   name: url.deletingPathExtension().lastPathComponent,
                                   date: doc.createdAt,
                                   matchCount: matches.count,
                                   snippets: Array(snippets)))
        }
        return hits.sorted { $0.matchCount > $1.matchCount }
    }
}
