import Foundation

/// Finds the whisper-cli binary and the large-v3 model.
///
/// In a shipped build these are bundled inside the app. During development we
/// fall back to the local whisper.cpp checkout so we can iterate without
/// copying a 3 GB model into every build.
enum EngineLocator {
    private static func devPath(_ rel: String) -> URL {
        URL(fileURLWithPath: (("~/Developer/whisper.cpp/" + rel) as NSString).expandingTildeInPath)
    }

    static var whisperCLI: URL? {
        if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let dev = devPath("build/bin/whisper-cli")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    static var model: URL? {
        if let bundled = Bundle.main.url(forResource: "ggml-large-v3", withExtension: "bin") {
            return bundled
        }
        let dev = devPath("models/ggml-large-v3.bin")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// Silero VAD model (optional — enables the "reduce silence hallucinations" feature).
    static var vadModel: URL? {
        if let bundled = Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin") {
            return bundled
        }
        let dev = devPath("models/ggml-silero-v5.1.2.bin")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static var isReady: Bool { whisperCLI != nil && model != nil }
}
