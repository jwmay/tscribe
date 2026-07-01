import Foundation

// Dev-only end-to-end probe: extract audio → transcribe → print.
// Usage: tscribe-probe <media-file>

func log(_ s: String) { print(s); fflush(stdout) }

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: tscribe-probe <media-file>\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let tmpWav = FileManager.default.temporaryDirectory
    .appendingPathComponent("probe-\(UUID().uuidString).wav")

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        log("• extracting audio → \(tmpWav.lastPathComponent)")
        try await AudioExtractor.extractWAV(from: input, to: tmpWav)
        let size = (try? FileManager.default.attributesOfItem(atPath: tmpWav.path)[.size] as? Int) ?? nil
        log("  wav bytes: \(size ?? 0)")

        log("• transcribing (large-v3)…")
        let transcript = try await TranscriptionService().transcribe(wav: tmpWav) { p in
            log(String(format: "  progress %.0f%%", p * 100))
        }

        log("\n=== TRANSCRIPT (\(transcript.segments.count) segments) ===")
        for seg in transcript.segments {
            log(String(format: "[%6.2f → %6.2f]  %@", seg.start, seg.end, seg.text as NSString))
        }

        log("\n=== WORD CONFIDENCE (first segment) ===")
        for w in transcript.segments.first?.words ?? [] {
            log(String(format: "  %-16@ conf=%.2f  (%.2f→%.2f)",
                       w.text as NSString, w.confidence, w.start, w.end))
        }

        try? FileManager.default.removeItem(at: tmpWav)
        sem.signal()
    } catch {
        log("ERROR: \(error.localizedDescription)")
        try? FileManager.default.removeItem(at: tmpWav)
        exit(1)
    }
}
sem.wait()
