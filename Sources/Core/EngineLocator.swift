import Foundation

/// Finds the whisper-cli binary and the large-v3 model.
///
/// Resolution order for the model is **downloaded → bundled → dev-fallback**:
/// - Downloaded: the Standard edition writes the model to Application Support at first
///   launch (see `ModelInstaller`), outside the signed app bundle.
/// - Bundled: the Complete edition ships the 2.9 GB model inside `Contents/Resources`.
/// - Dev-fallback (**`#if DEBUG` only**): during development we use the local
///   whisper.cpp checkout so we can iterate without bundling or downloading a 3 GB
///   model. Shipped Release/ReleaseStandard builds never look at `~/Developer/whisper.cpp`
///   — so a packaged Standard build reliably triggers first-launch onboarding on any Mac.
///
/// `whisperCLI` and `vadModel` are bundled in **both** editions (they are small),
/// so only the big model is ever downloaded.
enum EngineLocator {
    #if DEBUG
    private static func devPath(_ rel: String) -> URL {
        URL(fileURLWithPath: (("~/Developer/whisper.cpp/" + rel) as NSString).expandingTildeInPath)
    }

    /// Dev-only: the repo's committed `engine/` directory, located from this file's
    /// compile-time path. Lets Debug builds find the (small, vendored) diarization
    /// artifacts with no setup — they aren't copied into the bundle until packaging.
    private static func enginePath(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)      // …/Sources/Core/EngineLocator.swift
            .deletingLastPathComponent()     // …/Sources/Core
            .deletingLastPathComponent()     // …/Sources
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("engine/\(name)")
    }
    #endif

    // MARK: Writable install location (Standard edition)

    /// `~/Library/Application Support/Tscribe/models` — a writable location outside
    /// the signed `.app`. Installing here (rather than into `Contents/Resources`)
    /// keeps the app's code signature intact.
    static var appSupportModelsDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Tscribe/models", isDirectory: true)
    }

    /// Where the Standard edition installs the downloaded large-v3 model.
    static var downloadedModelURL: URL {
        appSupportModelsDir.appendingPathComponent("ggml-large-v3.bin")
    }

    // MARK: Resolution

    static var whisperCLI: URL? {
        if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        #if DEBUG
        let dev = devPath("build/bin/whisper-cli")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        #endif
        return nil
    }

    static var model: URL? {
        // Downloaded (Standard) takes precedence so a future model upgrade or a corrupt
        // bundled copy can be superseded without touching the app bundle.
        let downloaded = downloadedModelURL
        if FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        if let bundled = Bundle.main.url(forResource: "ggml-large-v3", withExtension: "bin") {
            return bundled
        }
        #if DEBUG
        let dev = devPath("models/ggml-large-v3.bin")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }

    /// Silero VAD model (optional — enables the "reduce silence hallucinations" feature).
    static var vadModel: URL? {
        if let bundled = Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin") {
            return bundled
        }
        #if DEBUG
        let dev = devPath("models/ggml-silero-v5.1.2.bin")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }

    /// True when the large-v3 model is bundled inside the app (Complete edition).
    /// False in the Standard edition, which downloads it on first launch.
    static var isModelBundled: Bool {
        Bundle.main.url(forResource: "ggml-large-v3", withExtension: "bin") != nil
    }

    static var isReady: Bool { whisperCLI != nil && model != nil }

    // MARK: Speaker diarization (optional, bundled in both editions)
    //
    // The diarizer + its two ONNX models are small and vendored in `engine/`, so
    // they ship in both editions and are never downloaded — no network, no onboarding.
    // Resolution mirrors `whisperCLI`/`vadModel` (bundled → `#if DEBUG` dev-fallback).
    // When any is missing the "Identify Speakers" feature simply hides itself.

    /// The sherpa-onnx offline speaker-diarization CLI.
    static var diarizeCLI: URL? {
        if let bundled = Bundle.main.url(forResource: "sherpa-onnx-offline-speaker-diarization", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        #if DEBUG
        let dev = enginePath("sherpa-onnx-offline-speaker-diarization")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        #endif
        return nil
    }

    /// Segmentation model (pyannote segmentation-3.0, ONNX).
    static var segmentationModel: URL? {
        if let bundled = Bundle.main.url(forResource: "diarize-segmentation", withExtension: "onnx") {
            return bundled
        }
        #if DEBUG
        let dev = enginePath("diarize-segmentation.onnx")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }

    /// Speaker-embedding model (WeSpeaker VoxCeleb, ONNX).
    static var embeddingModel: URL? {
        if let bundled = Bundle.main.url(forResource: "diarize-embedding", withExtension: "onnx") {
            return bundled
        }
        #if DEBUG
        let dev = enginePath("diarize-embedding.onnx")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }

    /// True when the diarizer and both models are available.
    static var isDiarizationAvailable: Bool {
        diarizeCLI != nil && segmentationModel != nil && embeddingModel != nil
    }
}
