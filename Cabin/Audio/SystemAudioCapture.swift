import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case screenRecordingDenied
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for system audio capture."
        case .screenRecordingDenied:
            return "Cabin needs “Screen & System Audio Recording” permission. Enable it in System Settings → Privacy & Security, then restart Cabin."
        case .microphoneDenied:
            return "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
        }
    }
}

/// Captures everything the Mac plays (all apps, excluding Cabin itself) via ScreenCaptureKit.
/// Emits 16 kHz mono samples on a background queue.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSamples: (([Float]) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "cabin.system-audio", qos: .userInitiated)
    private let converter = PCMConverter()

    func start() async throws {
        if !CGPreflightScreenCaptureAccess() {
            // Triggers the system prompt the first time.
            _ = CGRequestScreenCaptureAccess()
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.screenRecordingDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let ownBundleID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // We only want audio; keep the (mandatory) video stream as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = converter.convert(pcm)
        if !samples.isEmpty { onSamples?(samples) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onError?(error)
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
