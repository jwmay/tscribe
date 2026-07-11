import Foundation

enum DiarizationError: LocalizedError {
    case engineMissing
    case processFailed(Int32)
    case noSpeakersFound

    var errorDescription: String? {
        switch self {
        case .engineMissing:        return "The speaker-identification engine could not be found."
        case .processFailed(let c): return "Speaker identification failed (exit code \(c))."
        case .noSpeakersFound:      return "No speakers could be identified in this recording."
        }
    }
}

// `SpeakerTurn` (the diarizer's output unit) is defined in SpeakerMerge.swift so the
// pure merge logic compiles/tests without this file's Process/Bundle dependencies.

/// Runs the bundled sherpa-onnx offline speaker-diarization CLI on a 16 kHz WAV
/// (pyannote segmentation + WeSpeaker embedding + clustering) and parses its turns.
/// Mirrors `TranscriptionService`: spawn a `Process`, wait, parse stdout.
final class DiarizationService {
    func diarize(wav: URL,
                 numSpeakers: Int?,
                 progress: @escaping (Double) -> Void = { _ in }) async throws -> [SpeakerTurn] {
        guard let cli = EngineLocator.diarizeCLI,
              let seg = EngineLocator.segmentationModel,
              let emb = EngineLocator.embeddingModel else {
            throw DiarizationError.engineMissing
        }

        var args = [
            "--segmentation.pyannote-model=\(seg.path)",
            "--embedding.model=\(emb.path)",
            "--segmentation.num-threads=4",
            "--embedding.num-threads=4",
        ]
        // A known speaker count is the single biggest accuracy lever; otherwise let
        // the engine auto-detect the count from the clustering distance threshold.
        if let n = numSpeakers, n > 0 {
            args.append("--clustering.num-clusters=\(n)")
        } else {
            args.append("--clustering.cluster-threshold=0.5")
        }
        args.append(wav.path)

        let proc = Process()
        proc.executableURL = cli
        proc.arguments = args

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        // sherpa prints progress like "xx%" to stderr; scrape it best-effort.
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if let pct = Self.percent(in: String(line)) {
                    progress(min(max(pct / 100.0, 0), 1))
                }
            }
        }

        progress(0)
        try proc.run()

        // Drain stdout on a background thread *concurrently* with waiting, so a long
        // run can't wedge on a full 64 KB pipe buffer, and we hold no lock across a
        // suspension point.
        let outHandle = outPipe.fileHandleForReading
        let readTask = Task.detached(priority: .userInitiated) { outHandle.readDataToEndOfFile() }
        await Task.detached(priority: .userInitiated) { proc.waitUntilExit() }.value
        errPipe.fileHandleForReading.readabilityHandler = nil
        let captured = await readTask.value

        guard proc.terminationStatus == 0 else {
            throw DiarizationError.processFailed(proc.terminationStatus)
        }

        let turns = Self.parseTurns(String(decoding: captured, as: UTF8.self))
        guard !turns.isEmpty else { throw DiarizationError.noSpeakersFound }
        progress(1.0)
        return turns
    }

    /// Parse the CLI's per-turn lines, which look like `0.318 -- 6.865 speaker_00`.
    /// We split each line at the `speaker_` token: the integer right after it is the
    /// speaker index, and the two decimals before it are the start/end seconds. This
    /// deliberately ignores the config-echo line (it prints type names like
    /// `SpeakerEmbeddingExtractorConfig`, which contain "speaker" but never
    /// "speaker_"), the "Started" banner, and any other non-turn noise.
    static func parseTurns(_ output: String) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard let spk = line.range(of: "speaker_", options: .caseInsensitive) else { continue }
            let idxDigits = line[spk.upperBound...].prefix { $0.isNumber }
            guard let idx = Int(idxDigits) else { continue }
            let nums = decimals(in: String(line[..<spk.lowerBound]))
            guard nums.count >= 2, nums[1] > nums[0] else { continue }
            turns.append(SpeakerTurn(start: nums[0], end: nums[1], speakerIndex: idx))
        }
        return turns.sorted { $0.start < $1.start }
    }

    /// The number immediately preceding a `%` in a line, if any (progress scraping).
    private static func percent(in line: String) -> Double? {
        guard let pctIdx = line.firstIndex(of: "%") else { return nil }
        var digits = ""
        var i = pctIdx
        while i > line.startIndex {
            i = line.index(before: i)
            let ch = line[i]
            if ch.isNumber || ch == "." { digits.insert(ch, at: digits.startIndex) } else { break }
        }
        return Double(digits)
    }

    /// Extract every decimal/integer literal from a line, in order.
    private static func decimals(in line: String) -> [Double] {
        var result: [Double] = []
        var current = ""
        func flush() {
            if !current.isEmpty, let v = Double(current) { result.append(v) }
            current = ""
        }
        for ch in line {
            if ch.isNumber || ch == "." {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return result
    }
}
