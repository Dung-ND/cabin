import AVFoundation

/// Captures the default input device (your voice). Emits 16 kHz mono samples.
final class MicrophoneCapture {
    var onSamples: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let converter = PCMConverter()
    private var running = false

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(echoCancellation: Bool) throws {
        guard !running else { return }
        let input = engine.inputNode
        if echoCancellation {
            // Removes what the speakers play from the mic signal, so remote voices aren't transcribed twice.
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.converter.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
