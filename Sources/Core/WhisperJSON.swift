import Foundation

/// Decodes whisper.cpp `-ojf` (output-json-full) files into our domain model.
enum WhisperJSON {
    // MARK: Raw JSON shapes (subset of whisper.cpp output we care about)

    private struct Root: Decodable { let transcription: [Seg] }

    private struct Seg: Decodable {
        let offsets: Offsets
        let text: String
        let tokens: [Token]
    }

    private struct Offsets: Decodable { let from: Int; let to: Int } // milliseconds

    private struct Token: Decodable {
        let text: String
        let offsets: Offsets
        let p: Double
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> Transcript {
        let root = try JSONDecoder().decode(Root.self, from: data)
        let segments = root.transcription.map { seg -> Segment in
            Segment(
                start: Double(seg.offsets.from) / 1000.0,
                end: Double(seg.offsets.to) / 1000.0,
                text: seg.text.trimmingCharacters(in: .whitespaces),
                words: mergeTokensIntoWords(seg.tokens)
            )
        }
        return Transcript(segments: segments)
    }

    /// whisper emits sub-word tokens; a new word begins on a leading space.
    /// Merge consecutive tokens into words, taking the min token probability as
    /// the word confidence so a single shaky sub-token flags the whole word.
    private static func mergeTokensIntoWords(_ tokens: [Token]) -> [Word] {
        var words: [Word] = []
        for tok in tokens {
            let raw = tok.text
            if raw.hasPrefix("[_") { continue }            // special tokens
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let startsNewWord = raw.hasPrefix(" ") || words.isEmpty
            if startsNewWord {
                words.append(Word(
                    text: raw.trimmingCharacters(in: .whitespaces),
                    start: Double(tok.offsets.from) / 1000.0,
                    end: Double(tok.offsets.to) / 1000.0,
                    confidence: tok.p
                ))
            } else if var last = words.popLast() {
                last.text += raw
                last.end = Double(tok.offsets.to) / 1000.0
                last.confidence = min(last.confidence, tok.p)
                words.append(last)
            }
        }
        return words
    }
}
