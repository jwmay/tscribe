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
enum AudioExtractor {
    static let sampleRate = 16_000

    static func extractWAV(from url: URL, to outURL: URL) async throws {
        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
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

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
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

        try wavData(fromPCM: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
            .write(to: outURL)
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
