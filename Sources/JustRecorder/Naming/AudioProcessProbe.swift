import Foundation
import CoreAudio

/// Best-effort Core Audio output-process probe on macOS 14.4+.
/// Raw selectors also allow compilation with earlier SDKs.
enum AudioProcessProbe {

    private static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) | (scalar.value & 0xFF)
        }
        return result
    }

    private static let processListSelector = fourCC("prs#")
    private static let pidSelector = fourCC("ppid")
    /// `kAudioProcessPropertyIsRunningOutput`. Resolved from its four-char code rather
    /// than the SDK symbol so this file also builds against pre-14.4 SDKs; if the HAL
    /// does not answer it, the probe switches itself off.
    private static let runningOutputSelector = fourCC("piro")

    /// Guards the one-shot resolution below. `pidsCurrentlyPlayingAudio` can be called
    /// from the detection queue and from the Settings "Test detection" path at the same
    /// time, so the cache may not be a bare `var`.
    private static let resolutionLock = NSLock()
    private static var didResolveSelector = false
    /// The selector this OS build answered, or `nil` once the probe is known to be
    /// unavailable here. Resolved exactly once per launch.
    private static var resolvedRunningOutputSelector: UInt32?

    /// PIDs that currently have active audio output, or an empty set when unavailable.
    static func pidsCurrentlyPlayingAudio() -> Set<pid_t> {
        guard #available(macOS 14.4, *) else { return [] }

        // Cheap early out once the probe has been found unusable: no HAL round-trips,
        // no log lines, straight to the window-title fallback.
        guard !isKnownUnavailable else { return [] }

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard let objectIDs = readObjectIDList(from: systemObject, selector: processListSelector),
              !objectIDs.isEmpty
        else { return [] }

        guard let selector = runningOutputSelector(probingAgainst: objectIDs) else { return [] }

        var result = Set<pid_t>()
        for objectID in objectIDs where (readUInt32(objectID, selector: selector) ?? 0) != 0 {
            if let pid = readPID(objectID) { result.insert(pid) }
        }
        return result
    }

    // MARK: - One-shot selector resolution

    private static var isKnownUnavailable: Bool {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        return didResolveSelector && resolvedRunningOutputSelector == nil
    }

    /// Resolves the "is running output" selector once, under the lock, by asking the
    /// first few process objects. A failure is latched — the probe stays off for the rest
    /// of the launch and is logged a single time.
    private static func runningOutputSelector(probingAgainst objectIDs: [AudioObjectID]) -> UInt32? {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }

        if didResolveSelector { return resolvedRunningOutputSelector }

        let selector = runningOutputSelector
        for objectID in objectIDs.prefix(8) where readUInt32(objectID, selector: selector) != nil {
            didResolveSelector = true
            resolvedRunningOutputSelector = selector
            return selector
        }

        didResolveSelector = true
        resolvedRunningOutputSelector = nil
        Log.info("Core Audio output probe unavailable on this system; using window titles instead.")
        return nil
    }

    // MARK: - Core Audio helpers

    private static func readObjectIDList(from object: AudioObjectID, selector: UInt32) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &objectIDs) == noErr else {
            return nil
        }
        return objectIDs
    }

    private static func readUInt32(_ object: AudioObjectID, selector: UInt32) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func readPID(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: pidSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value) == noErr,
              value > 0
        else { return nil }
        return value
    }
}
