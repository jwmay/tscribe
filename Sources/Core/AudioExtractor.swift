import Foundation
import AVFoundation
import CoreMedia

enum AudioExtractionError: LocalizedError {
    case noAudioTrack
    case cannotCreateReader(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:            return "This file has no audio track to transcribe."
        case .cannotCreateReader(let m): return "Could not open the file: \(m)"
        case .readFailed(let m):       return "Could not read the audio: \(m)"
        }
    }
}

/// Extracts a 16 kHz mono 16-bit PCM WAV from any AVFoundation-readable
/// video/audio file (mp4, mov, m4a, wav, aac, ...). Fully local — no ffmpeg.
///
/// Reads **all** audio tracks mixed together, not just the first: courtroom /
/// hearing recorders (FTR, JAVS, …) write one track per microphone, and the
/// first is often a nearly-silent feed — transcribing only that one produced
/// hallucination loops. The mixed signal is then peak-normalized, because
/// courtroom mics are typically recorded very quiet and Whisper degrades
/// badly on low-level audio.
enum AudioExtractor {
    static let sampleRate = 16_000

    static func extractWAV(from url: URL, to outURL: URL) async throws {
        let asset = AVURLAsset(url: url)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw AudioExtractionError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioExtractionError.cannotCreateReader(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        // Mixes every audio track into one mono stream (a single track passes through).
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioExtractionError.readFailed("cannot attach PCM output")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw AudioExtractionError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var pcm = Data()
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block)
                if length > 0 {
                    var chunk = Data(count: length)
                    chunk.withUnsafeMutableBytes { ptr in
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                       destination: ptr.baseAddress!)
                    }
                    pcm.append(chunk)
                }
            }
            CMSampleBufferInvalidate(sample)
        }

        if reader.status == .failed {
            throw AudioExtractionError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }

        normalizePeak(&pcm)

        try wavData(fromPCM: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
            .write(to: outURL)
    }

    /// Boost quiet audio so its peak sits near full scale (~-1 dB). Gain is
    /// capped at 30 dB so a silent recording doesn't become pure amplified
    /// noise, and audio that is already loud is left untouched.
    private static func normalizePeak(_ pcm: inout Data) {
        pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return }

            var maxAbs: Int32 = 0
            for s in samples { maxAbs = max(maxAbs, abs(Int32(s))) }
            guard maxAbs > 0 else { return }

            let target: Int32 = 29_000                       // ≈ -1 dBFS
            let gain = min(Double(target) / Double(maxAbs), 32.0)  // cap ≈ +30 dB
            guard gain > 1.05 else { return }                // already loud enough

            for i in samples.indices {
                let v = Double(samples[i]) * gain
                samples[i] = Int16(max(-32_768, min(32_767, v)))
            }
        }
    }

    /// Wrap raw little-endian PCM in a canonical 44-byte WAV header.
    private static func wavData(fromPCM pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcm.count

        var header = Data()
        func str(_ s: String) { header.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }

        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1)                       // PCM
        u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        str("data"); u32(UInt32(dataSize))

        var out = header
        out.append(pcm)
        return out
    }
}
