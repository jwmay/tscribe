import Foundation

enum TranscriptionError: LocalizedError {
    case engineMissing
    case processFailed(Int32)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .engineMissing:       return "The transcription engine or model could not be found."
        case .processFailed(let c): return "Transcription failed (exit code \(c))."
        case .noOutput:            return "The engine produced no output."
        }
    }
}

struct TranscriptionOptions {
    var language = "en"          // "auto" to detect
    var translate = false
    var beamSize = 5
    var suppressNonSpeech = true
    var dtwPreset: String? = "large.v3"   // tighter word timestamps
    var useVAD = false                    // skip silence to cut hallucinations
}

/// Runs the bundled whisper-cli on a 16 kHz WAV and parses the result.
final class TranscriptionService {
    func transcribe(wav: URL,
                    options: TranscriptionOptions = .init(),
                    progress: @escaping (Double) -> Void) async throws -> Transcript {
        guard let cli = EngineLocator.whisperCLI, let model = EngineLocator.model else {
            throw TranscriptionError.engineMissing
        }

        let outBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("tscribe-\(UUID().uuidString)")
        let jsonURL = outBase.appendingPathExtension("json")

        var args = [
            "-m", model.path,
            "-f", wav.path,
            "-of", outBase.path,
            "-ojf",
            "--print-progress",
            "-bo", String(options.beamSize),
            "-bs", String(options.beamSize),
            "-l", options.language
        ]
        if options.translate { args.append("--translate") }
        if options.suppressNonSpeech { args.append("--suppress-nst") }
        if let dtw = options.dtwPreset { args += ["-dtw", dtw] }
        if options.useVAD, let vad = EngineLocator.vadModel {
            // 60 ms speech padding avoids clipping word onsets at segment edges.
            args += ["--vad", "--vad-model", vad.path, "-vp", "60"]
        }

        let proc = Process()
        proc.executableURL = cli
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice   // transcript text; we read the JSON file instead

        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") {
                guard let r = line.range(of: "progress =") else { continue }
                let tail = line[r.upperBound...]
                if let pctStr = tail.split(separator: "%").first,
                   let pct = Double(pctStr.trimmingCharacters(in: .whitespaces)) {
                    progress(min(max(pct / 100.0, 0), 1))
                }
            }
        }

        try proc.run()
        await Task.detached(priority: .userInitiated) { proc.waitUntilExit() }.value
        errPipe.fileHandleForReading.readabilityHandler = nil

        guard proc.terminationStatus == 0 else {
            throw TranscriptionError.processFailed(proc.terminationStatus)
        }
        guard let data = try? Data(contentsOf: jsonURL) else {
            throw TranscriptionError.noOutput
        }
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        progress(1.0)
        return try WhisperJSON.parse(data)
    }
}
