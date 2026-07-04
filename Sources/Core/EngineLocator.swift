import Foundation

/// Finds the whisper-cli binary and the large-v3 model.
///
/// Resolution order for the model is **downloaded → bundled → dev-fallback**:
/// - Downloaded: the Lite edition writes the model to Application Support at first
///   launch (see `ModelInstaller`), outside the signed app bundle.
/// - Bundled: the Full edition ships the 2.9 GB model inside `Contents/Resources`.
/// - Dev-fallback: during development we use the local whisper.cpp checkout so we
///   can iterate without copying a 3 GB model into every build.
///
/// `whisperCLI` and `vadModel` are bundled in **both** editions (they are small),
/// so only the big model is ever downloaded.
enum EngineLocator {
    private static func devPath(_ rel: String) -> URL {
        URL(fileURLWithPath: (("~/Developer/whisper.cpp/" + rel) as NSString).expandingTildeInPath)
    }

    // MARK: Writable install location (Lite edition)

    /// `~/Library/Application Support/Tscribe/models` — a writable location outside
    /// the signed `.app`. Installing here (rather than into `Contents/Resources`)
    /// keeps the app's code signature intact.
    static var appSupportModelsDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Tscribe/models", isDirectory: true)
    }

    /// Where the Lite edition installs the downloaded large-v3 model.
    static var downloadedModelURL: URL {
        appSupportModelsDir.appendingPathComponent("ggml-large-v3.bin")
    }

    // MARK: Resolution

    static var whisperCLI: URL? {
        if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let dev = devPath("build/bin/whisper-cli")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    static var model: URL? {
        // Downloaded (Lite) takes precedence so a future model upgrade or a corrupt
        // bundled copy can be superseded without touching the app bundle.
        let downloaded = downloadedModelURL
        if FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
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

    /// True when the large-v3 model is bundled inside the app (Full edition).
    /// False in the Lite edition, which downloads it on first launch.
    static var isModelBundled: Bool {
        Bundle.main.url(forResource: "ggml-large-v3", withExtension: "bin") != nil
    }

    static var isReady: Bool { whisperCLI != nil && model != nil }
}
