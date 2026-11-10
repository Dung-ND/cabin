import Foundation

/// A piece of continuous speech ready for transcription.
struct AudioChunk {
    let source: AudioSourceKind
    let samples: [Float]          // 16 kHz mono
    let startedAt: Date
    var duration: TimeInterval { Double(samples.count) / PCMConverter.targetSampleRate }
    var endedAt: Date { startedAt.addingTimeInterval(duration) }
}

/// Energy-based voice activity chunking: groups audio into utterances that end at a pause,
/// capped at `maxDuration` so transcripts appear quickly. Not thread-safe; feed from one queue.
final class UtteranceChunker {
    struct Config {
        var frameDuration: TimeInterval = 0.03
        var minSilenceToSplit: TimeInterval = 0.7
        var minChunk: TimeInterval = 1.2
        var maxChunk: TimeInterval = 18
        var minSpeech: TimeInterval = 0.4
        var preRoll: TimeInterval = 0.3
        /// Speech must be this many times louder than the adaptive noise floor.
        var speechToNoiseRatio: Float = 3
        var absoluteMinRMS: Float = 0.004
    }

    let source: AudioSourceKind
    var config: Config
    var onChunk: ((AudioChunk) -> Void)?

    private let sampleRate = PCMConverter.targetSampleRate
    private var pending: [Float] = []       // samples not yet framed
    private var buffer: [Float] = []        // current utterance (incl. pre-roll)
    private var preRoll: [Float] = []
    private var bufferStart: Date?
    private var speechFrames = 0
    private var silenceFrames = 0
    private var inSpeech = false
    private var noiseFloor: Float = 0.002
    private let clock: () -> Date

    init(source: AudioSourceKind, config: Config = Config(), clock: @escaping () -> Date = { Date() }) {
        self.source = source
        self.config = config
        self.clock = clock
    }

    private var frameLength: Int { Int(config.frameDuration * sampleRate) }

    func append(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        let now = clock()     // wall-clock time of the last sample received
        let n = frameLength
        var offset = 0
        while pending.count - offset >= n {
            let frame = Array(pending[offset..<(offset + n)])
            offset += n
            let frameEnd = now.addingTimeInterval(-Double(pending.count - offset) / sampleRate)
            process(frame: frame, endingAt: frameEnd)
        }
        pending.removeFirst(offset)
    }

    /// Emits whatever speech is buffered (call when stopping).
    func flush() {
        emitIfSpeech()
        reset()
    }

    private func process(frame: [Float], endingAt frameEnd: Date) {
        let rms = Self.rms(frame)
        let threshold = max(config.absoluteMinRMS, noiseFloor * config.speechToNoiseRatio)
        let isSpeech = rms > threshold
        if !isSpeech {
            // Slowly track background noise level.
            noiseFloor = noiseFloor * 0.98 + rms * 0.02
        }

        if !inSpeech {
            if isSpeech {
                inSpeech = true
                // Start time = end of this frame minus the audio we already hold.
                let held = Double(preRoll.count + frame.count) / sampleRate
                bufferStart = frameEnd.addingTimeInterval(-held)
                buffer = preRoll + frame
                speechFrames = 1
                silenceFrames = 0
            } else {
                preRoll.append(contentsOf: frame)
                let maxPre = Int(config.preRoll * sampleRate)
                if preRoll.count > maxPre { preRoll.removeFirst(preRoll.count - maxPre) }
            }
            return
        }

        buffer.append(contentsOf: frame)
        if isSpeech {
            speechFrames += 1
            silenceFrames = 0
        } else {
            silenceFrames += 1
        }

        let duration = Double(buffer.count) / sampleRate
        let silence = Double(silenceFrames) * config.frameDuration
        if (silence >= config.minSilenceToSplit && duration >= config.minChunk) || duration >= config.maxChunk {
            emitIfSpeech()
            reset()
        }
    }

    private func emitIfSpeech() {
        let speech = Double(speechFrames) * config.frameDuration
        guard inSpeech, speech >= config.minSpeech, let start = bufferStart else { return }
        onChunk?(AudioChunk(source: source, samples: buffer, startedAt: start))
    }

    private func reset() {
        buffer = []
        preRoll = []
        bufferStart = nil
        speechFrames = 0
        silenceFrames = 0
        inSpeech = false
    }

    static func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for s in frame { sum += s * s }
        return (sum / Float(frame.count)).squareRoot()
    }
}
