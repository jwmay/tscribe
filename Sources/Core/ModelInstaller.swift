#if LITE
import Foundation
import CryptoKit

/// Identity of the large-v3 model the Lite edition downloads on first launch.
///
/// These constants are captured from the exact artifact the Full edition bundles,
/// and are enforced at package time by the drift-guard in `scripts/package.sh`,
/// so the Lite download is guaranteed to be the same bytes.
enum ModelSpec {
    static let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!
    static let expectedBytes: Int64 = 3_095_033_483
    static let sha256 = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
    /// ~6 GB: the transient peak while both the staged copy and the final file
    /// briefly coexist during install.
    static let requiredFreeBytes: Int64 = 6_000_000_000

    static var displayBytes: String {
        ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    }
}

/// What went wrong during a model install. User-facing via `errorDescription`.
enum InstallError: LocalizedError, Equatable {
    case noNetwork
    case diskFull(required: Int64, available: Int64)
    case serverError(Int)
    case sizeMismatch(expected: Int64, got: Int64)
    case checksumMismatch
    case cancelled
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .noNetwork:
            return "Couldn't reach the download server. Check your internet connection and try again."
        case .diskFull(let required, _):
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            return "Not enough free disk space. About \(need) is needed to install the speech model."
        case .serverError(let code):
            return "The download server returned an error (HTTP \(code)). Please try again later."
        case .sizeMismatch:
            return "The downloaded file was incomplete. Please try again."
        case .checksumMismatch:
            return "The downloaded file didn't verify correctly. Please try again."
        case .cancelled:
            return "Download cancelled."
        case .ioError(let msg):
            return "The download couldn't be completed. \(msg)"
        }
    }
}

/// Downloads, verifies, and installs the large-v3 model for the Lite edition.
///
/// Robustness: streams straight to disk (never 2.9 GB in RAM), pre-checks free
/// space, verifies size + SHA-256 before installing, installs atomically (a
/// half-file is never treated as valid), and supports resume after cancel/quit.
final class ModelInstaller: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double, received: Int64, total: Int64, bytesPerSec: Double)
        case verifying
        case installing
        case done
        case failed(InstallError)
    }

    @Published private(set) var phase: Phase = .idle

    /// Called on the main thread once the model is verified and installed.
    var onInstalled: (() -> Void)?

    /// True when a partially-downloaded model can be resumed.
    var canResume: Bool { FileManager.default.fileExists(atPath: resumeURL.path) }

    private lazy var session: URLSession =
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionDownloadTask?
    private var sessionStart = Date()
    private var lastUIUpdate = Date.distantPast
    private var userCancelled = false

    // MARK: Paths

    private var modelsDir: URL { EngineLocator.appSupportModelsDir }
    private var stagingURL: URL { modelsDir.appendingPathComponent(".staging-ggml-large-v3.bin") }
    private var resumeURL: URL { modelsDir.appendingPathComponent(".resume") }
    private var finalURL: URL { EngineLocator.downloadedModelURL }

    // MARK: Public control

    /// Begin a fresh download.
    func start() {
        guard task == nil else { return }
        userCancelled = false
        do {
            try prepareDirectories()
            try checkFreeSpace()
        } catch let e as InstallError {
            phase = .failed(e)
            return
        } catch {
            phase = .failed(.ioError(error.localizedDescription))
            return
        }
        try? FileManager.default.removeItem(at: resumeURL)   // fresh start ⇒ drop stale resume data
        let t = session.downloadTask(with: ModelSpec.url)
        beginTask(t)
    }

    /// Resume a previously cancelled/interrupted download, or start fresh if none.
    func resume() {
        guard task == nil else { return }
        userCancelled = false
        guard let data = try? Data(contentsOf: resumeURL) else { start(); return }
        do {
            try prepareDirectories()
            try checkFreeSpace()
        } catch let e as InstallError {
            phase = .failed(e)
            return
        } catch {
            phase = .failed(.ioError(error.localizedDescription))
            return
        }
        let t = session.downloadTask(withResumeData: data)
        beginTask(t)
    }

    /// Cancel an in-flight download, preserving resume data so it can continue later.
    func cancel() {
        userCancelled = true
        task?.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            if let data { try? data.write(to: self.resumeURL, options: .atomic) }
        })
        task = nil
        setPhase(.idle)
    }

    /// Install a model file the user already has on disk (offline / failed-download
    /// escape hatch). Verifies size + SHA-256 before accepting it.
    func installFromFile(_ url: URL) {
        setPhase(.verifying)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.prepareDirectories()
                try? FileManager.default.removeItem(at: self.stagingURL)
                try FileManager.default.copyItem(at: url, to: self.stagingURL)
                try self.verifyAndInstall()
            } catch let e as InstallError {
                try? FileManager.default.removeItem(at: self.stagingURL)
                self.setPhase(.failed(e))
            } catch {
                try? FileManager.default.removeItem(at: self.stagingURL)
                self.setPhase(.failed(.ioError(error.localizedDescription)))
            }
        }
    }

    // MARK: Internals

    private func beginTask(_ t: URLSessionDownloadTask) {
        task = t
        sessionStart = Date()
        lastUIUpdate = .distantPast
        setPhase(.downloading(fraction: 0, received: 0, total: ModelSpec.expectedBytes, bytesPerSec: 0))
        t.resume()
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }

    private func checkFreeSpace() throws {
        let values = try modelsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        if available > 0 && available < ModelSpec.requiredFreeBytes {
            throw InstallError.diskFull(required: ModelSpec.requiredFreeBytes, available: available)
        }
    }

    /// Verify the staged file (size then SHA-256) and, on success, atomically install it.
    /// Runs off the main thread. Throws `InstallError` on any failure.
    private func verifyAndInstall() throws {
        setPhase(.verifying)

        let size = (try FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? Int64) ?? -1
        guard size == ModelSpec.expectedBytes else {
            throw InstallError.sizeMismatch(expected: ModelSpec.expectedBytes, got: size)
        }

        let digest = try sha256Hex(of: stagingURL)
        guard digest.caseInsensitiveCompare(ModelSpec.sha256) == .orderedSame else {
            throw InstallError.checksumMismatch
        }

        setPhase(.installing)
        // Same-volume rename ⇒ the final path is only ever the fully-verified file.
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)

        UserDefaults.standard.set(ModelSpec.sha256, forKey: "installedModelSHA")
        UserDefaults.standard.set(ModelSpec.expectedBytes, forKey: "installedModelBytes")
        try? FileManager.default.removeItem(at: resumeURL)

        setPhase(.done)
        DispatchQueue.main.async { [weak self] in self?.onInstalled?() }
    }

    /// Streamed SHA-256 — reads the file in chunks so memory stays flat for 2.9 GB.
    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done: Bool = autoreleasepool {
                let chunk = handle.readData(ofLength: 8 * 1024 * 1024)
                if chunk.isEmpty { return true }
                hasher.update(data: chunk)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func mapURLError(_ error: Error) -> InstallError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed, NSURLErrorTimedOut,
                 NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
                return .noNetwork
            default:
                return .ioError(error.localizedDescription)
            }
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return .diskFull(required: ModelSpec.requiredFreeBytes, available: 0)
        }
        return .ioError(error.localizedDescription)
    }

    private func setPhase(_ p: Phase) {
        if Thread.isMainThread { phase = p }
        else { DispatchQueue.main.async { [weak self] in self?.phase = p } }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelInstaller: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastUIUpdate) >= 0.1 else { return }   // throttle UI to ~10/s
        lastUIUpdate = now

        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : ModelSpec.expectedBytes
        let fraction = total > 0 ? min(max(Double(totalBytesWritten) / Double(total), 0), 1) : 0
        let elapsed = now.timeIntervalSince(sessionStart)
        let rate = elapsed > 0 ? Double(totalBytesWritten) / elapsed : 0
        setPhase(.downloading(fraction: fraction, received: totalBytesWritten, total: total, bytesPerSec: rate))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Non-2xx (e.g. 404/429) still lands here with the error body — reject it.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            setPhase(.failed(.serverError(http.statusCode)))
            return
        }
        // The temp file is deleted when this method returns, so move it now.
        // Same volume ⇒ this is a fast rename; cross-volume falls back to a copy.
        do {
            try prepareDirectories()
            try? FileManager.default.removeItem(at: stagingURL)
            do { try FileManager.default.moveItem(at: location, to: stagingURL) }
            catch { try FileManager.default.copyItem(at: location, to: stagingURL) }
        } catch {
            setPhase(.failed(mapURLError(error)))
            return
        }
        // Verify + install off the delegate queue (SHA-256 over 2.9 GB is slow).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do { try self.verifyAndInstall() }
            catch let e as InstallError {
                try? FileManager.default.removeItem(at: self.stagingURL)
                self.setPhase(.failed(e))
            } catch {
                try? FileManager.default.removeItem(at: self.stagingURL)
                self.setPhase(.failed(.ioError(error.localizedDescription)))
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        self.task = nil
        guard let error else { return }   // success is handled in didFinishDownloadingTo
        if userCancelled { return }       // cancel() already set the phase + saved resume data

        let ns = error as NSError
        if let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: resumeURL, options: .atomic)
        }
        setPhase(.failed(mapURLError(error)))
    }
}
#endif
