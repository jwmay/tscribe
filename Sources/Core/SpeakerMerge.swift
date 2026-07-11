import Foundation

/// One diarized turn: a speaker index active over [start, end] seconds.
/// `speakerIndex` is raw engine output (0-based); `SpeakerMerge` maps it to A/B/C keys.
struct SpeakerTurn: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var speakerIndex: Int
}

/// Fuses diarization turns onto Whisper's word timestamps — pure Swift over the two
/// timelines, no audio, no ML. This is the standard "late fusion" merge used by
/// whisperX/whisper-diarization:
///   1. assign each word the speaker whose turns it overlaps most (nearest-turn fallback),
///   2. smooth mid-sentence speaker flips using sentence punctuation,
///   3. split each Whisper segment at speaker boundaries into single-speaker segments.
enum SpeakerMerge {
    static func assign(_ transcript: Transcript, turns rawTurns: [SpeakerTurn]) -> Transcript {
        let turns = rawTurns.sorted { $0.start < $1.start }
        guard !turns.isEmpty else { return transcript }

        // 1. Stable A/B/C… keys in first-appearance (time) order.
        var indexToKey: [Int: String] = [:]
        var order: [String] = []
        for t in turns where indexToKey[t.speakerIndex] == nil {
            let key = keyForOrdinal(order.count)
            indexToKey[t.speakerIndex] = key
            order.append(key)
        }

        // 2. Assign a speaker to every word (flattened in segment/word order).
        var flatWords: [Word] = []
        for seg in transcript.segments { flatWords.append(contentsOf: seg.words) }
        var keys = flatWords.map { speakerKey(forInterval: $0.start, $0.end, turns: turns, indexToKey: indexToKey) }

        // 3. Smooth mid-sentence flips.
        realign(&keys, words: flatWords)

        // 4. Split segments at speaker-change boundaries.
        var newSegments: [Segment] = []
        var cursor = 0
        for seg in transcript.segments {
            let n = seg.words.count
            if n == 0 {
                var s = seg
                s.speaker = speakerKey(forInterval: seg.start, seg.end, turns: turns, indexToKey: indexToKey)
                newSegments.append(s)
                continue
            }
            let segKeys = Array(keys[cursor..<(cursor + n)])
            cursor += n
            let segRuns = runs(of: segKeys)
            if segRuns.count == 1 {
                // Homogeneous — preserve original text (it may be user-edited).
                var s = seg
                s.speaker = segRuns[0].key
                newSegments.append(s)
            } else {
                for run in segRuns {
                    let runWords = Array(seg.words[run.range])
                    newSegments.append(Segment(
                        start: runWords.first!.start,
                        end: runWords.last!.end,
                        text: runWords.map(\.text).joined(separator: " "),
                        words: runWords,
                        speaker: run.key
                    ))
                }
            }
        }

        // 5. Roster in first-appearance order, preserving any existing user names.
        let existingNames = Dictionary(transcript.speakers.map { ($0.key, $0.name) },
                                       uniquingKeysWith: { a, _ in a })
        let roster = order.map { Speaker(key: $0, name: existingNames[$0] ?? "") }

        var out = transcript
        out.segments = newSegments
        out.speakers = roster
        return out
    }

    // MARK: Word → speaker (max overlap, nearest-turn fallback)

    static func speakerKey(forInterval start: TimeInterval, _ end: TimeInterval,
                           turns: [SpeakerTurn], indexToKey: [Int: String]) -> String {
        var overlap: [String: Double] = [:]
        for t in turns {
            let inter = min(t.end, end) - max(t.start, start)
            if inter > 0, let key = indexToKey[t.speakerIndex] { overlap[key, default: 0] += inter }
        }
        if let best = overlap.max(by: { $0.value < $1.value })?.key { return best }
        // No overlap (word in a gap / diarization miss): snap to the nearest turn by
        // midpoint so no word is ever left unlabeled.
        let mid = (start + end) / 2
        let nearest = turns.min {
            abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid)
        }!
        return indexToKey[nearest.speakerIndex] ?? order0(indexToKey)
    }

    private static func order0(_ map: [Int: String]) -> String { map.values.sorted().first ?? "A" }

    // MARK: Sentence-punctuation realignment (stops a speaker flipping mid-sentence)

    static func realign(_ keys: inout [String], words: [Word], maxSentence: Int = 50) {
        let n = keys.count
        guard n > 1 else { return }
        var k = 0
        while k < n {
            if k < n - 1, keys[k] != keys[k + 1], !isSentenceEnd(words[k].text) {
                let left = sentenceStart(k, words: words, cap: maxSentence)
                let right = sentenceEnd(k, words: words, cap: maxSentence, from: left)
                if left <= right {
                    let span = Array(keys[left...right])
                    if let majority = majorityKey(span),
                       span.filter({ $0 == majority }).count > span.count / 2 {
                        for i in left...right { keys[i] = majority }
                        k = right + 1
                        continue
                    }
                }
            }
            k += 1
        }
    }

    static func isSentenceEnd(_ text: String) -> Bool {
        // Last non-closing-quote/bracket character is terminal punctuation.
        guard let last = text.reversed().first(where: { !"\"')]}”’".contains($0) }) else { return false }
        return ".?!".contains(last)
    }

    private static func sentenceStart(_ k: Int, words: [Word], cap: Int) -> Int {
        var i = k, steps = 0
        while i > 0, !isSentenceEnd(words[i - 1].text), steps < cap { i -= 1; steps += 1 }
        return i
    }

    private static func sentenceEnd(_ k: Int, words: [Word], cap: Int, from left: Int) -> Int {
        var i = k
        while i < words.count - 1, !isSentenceEnd(words[i].text), (i - left) < cap { i += 1 }
        return i
    }

    static func majorityKey(_ span: [String]) -> String? {
        var counts: [String: Int] = [:]
        for s in span { counts[s, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: Helpers

    /// Contiguous runs of equal key; `range` indexes into the source array.
    static func runs(of keys: [String]) -> [(key: String, range: Range<Int>)] {
        guard !keys.isEmpty else { return [] }
        var result: [(String, Range<Int>)] = []
        var start = 0
        var i = 1
        while i <= keys.count {
            if i == keys.count || keys[i] != keys[start] {
                result.append((keys[start], start..<i))
                start = i
            }
            i += 1
        }
        return result
    }

    /// 0→A, 1→B, … 25→Z, then S27, S28, … (diarization rarely exceeds a few speakers).
    static func keyForOrdinal(_ n: Int) -> String {
        n < 26 ? String(UnicodeScalar(65 + n)!) : "S\(n + 1)"
    }
}
