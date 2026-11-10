import AppKit
import CoreAudio

struct AudioApp: Hashable {
    let bundleID: String
    let name: String
}

/// Polls Core Audio's process list (macOS 14.2+) to learn which apps are currently
/// playing audio (output) or using a microphone (input). Used to attribute transcripts to apps.
final class AudioActivityMonitor {
    struct Sample {
        let date: Date
        let output: [AudioApp]
        let input: [AudioApp]
    }

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cabin.audio-activity")
    private var history: [Sample] = []
    private let lock = NSLock()
    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Apps that were outputting (or capturing input) between two dates, most frequent first.
    func apps(from start: Date, to end: Date, input: Bool) -> [AudioApp] {
        lock.lock()
        let window = history.filter { $0.date >= start.addingTimeInterval(-0.5) && $0.date <= end.addingTimeInterval(0.5) }
        lock.unlock()
        var counts: [AudioApp: Int] = [:]
        for s in window {
            for app in (input ? s.input : s.output) { counts[app, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private func poll() {
        let processes = Self.processObjects()
        var output: Set<AudioApp> = []
        var input: Set<AudioApp> = []
        for obj in processes {
            let isOut = Self.uint32(obj, kAudioProcessPropertyIsRunningOutput) == 1
            let isIn = Self.uint32(obj, kAudioProcessPropertyIsRunningInput) == 1
            guard isOut || isIn else { continue }
            let pid = Self.pid(obj)
            let bundleID = Self.string(obj, kAudioProcessPropertyBundleID) ?? ""
            guard let app = resolveApp(pid: pid, bundleID: bundleID), app.bundleID != ownBundleID else { continue }
            if isOut { output.insert(app) }
            if isIn { input.insert(app) }
        }
        let sample = Sample(date: Date(), output: Array(output), input: Array(input))
        lock.lock()
        history.append(sample)
        let cutoff = Date().addingTimeInterval(-120)
        history.removeAll { $0.date < cutoff }
        lock.unlock()
    }

    /// Maps a (possibly helper) process to the user-facing app, e.g. "com.google.Chrome.helper" → Google Chrome.
    private func resolveApp(pid: pid_t, bundleID: String) -> AudioApp? {
        let running = NSWorkspace.shared.runningApplications
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
           let id = app.bundleIdentifier {
            return AudioApp(bundleID: id, name: app.localizedName ?? id)
        }
        // Helper process: find the regular app whose bundle id is the longest prefix.
        if !bundleID.isEmpty {
            let match = running
                .filter { $0.activationPolicy == .regular }
                .compactMap { app -> (NSRunningApplication, String)? in
                    guard let id = app.bundleIdentifier, bundleID.hasPrefix(id) else { return nil }
                    return (app, id)
                }
                .max { $0.1.count < $1.1.count }
            if let match { return AudioApp(bundleID: match.1, name: match.0.localizedName ?? match.1) }
            if bundleID.hasPrefix("com.apple.WebKit") {
                return AudioApp(bundleID: "com.apple.Safari", name: "Safari")
            }
            if bundleID.hasPrefix("com.apple.") && (bundleID.contains("coreaudiod") || bundleID.contains("audio")) {
                return nil
            }
            let short = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return AudioApp(bundleID: bundleID, name: short)
        }
        return nil
    }

    // MARK: Core Audio helpers

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func pid(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return -1 }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
