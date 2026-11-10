import AVFoundation

/// Converts arbitrary float PCM buffers into 16 kHz mono Float samples (what Whisper/Pyannote expect).
final class PCMConverter {
    static let targetSampleRate: Double = 16_000

    private var converter: AVAudioConverter?
    private var monoInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: PCMConverter.targetSampleRate,
                                             channels: 1, interleaved: false)!

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let mono = Self.downmix(buffer) else { return [] }
        if mono.format.sampleRate == Self.targetSampleRate {
            return Self.samples(of: mono)
        }
        if converter == nil || monoInputFormat?.sampleRate != mono.format.sampleRate {
            converter = AVAudioConverter(from: mono.format, to: outputFormat)
            monoInputFormat = mono.format
        }
        guard let converter else { return [] }

        let ratio = outputFormat.sampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error else { return [] }
        return Self.samples(of: out)
    }

    /// Averages all channels into a single non-interleaved float channel at the source sample rate.
    static func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                             channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)

        let interleaved = buffer.format.isInterleaved
        let scale = 1 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels {
                sum += interleaved ? src[0][i * channels + c] : src[c][i]
            }
            dst[i] = sum * scale
        }
        return mono
    }

    static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
