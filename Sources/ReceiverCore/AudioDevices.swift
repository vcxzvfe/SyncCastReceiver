import Foundation
import CoreAudio

/// One CoreAudio output device, as far as this daemon cares.
public struct AudioOutputDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let outputChannelCount: Int
    public let nominalSampleRate: Double
    public let isBuiltIn: Bool

    public var isUsable: Bool { outputChannelCount > 0 }
}

public enum AudioDeviceError: Error, CustomStringConvertible {
    case noOutputDevices
    case notFound(String)
    case coreAudio(String, OSStatus)

    public var description: String {
        switch self {
        case .noOutputDevices: return "no CoreAudio output devices are present"
        case .notFound(let q): return "no output device matches \"\(q)\""
        case .coreAudio(let what, let status): return "\(what) failed with OSStatus \(status)"
        }
    }
}

/// Enumeration and selection of output devices, plus the latency figures the
/// playout scheduler needs.
public enum AudioDevices {

    public static let builtInSpeakerUID = "BuiltInSpeakerDevice"

    public static func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { describe(deviceID: $0) }.filter(\.isUsable)
    }

    public static func describe(deviceID: AudioDeviceID) -> AudioOutputDevice? {
        let channels = outputChannelCount(deviceID)
        guard channels > 0 else { return nil }
        let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? ""
        let name = stringProperty(deviceID, kAudioObjectPropertyName) ?? uid
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return AudioOutputDevice(id: deviceID, uid: uid, name: name,
                                 outputChannelCount: channels,
                                 nominalSampleRate: rate,
                                 isBuiltIn: transportType(deviceID) == kAudioDeviceTransportTypeBuiltIn)
    }

    /// Resolve a `--device` argument: exact UID, then exact name, then a
    /// case-insensitive name substring. Nil selects the built-in speakers,
    /// falling back to the system default output.
    public static func resolve(query: String?) throws -> AudioOutputDevice {
        let devices = outputDevices()
        guard !devices.isEmpty else { throw AudioDeviceError.noOutputDevices }
        guard let query, !query.isEmpty else {
            if let speakers = devices.first(where: { $0.uid == builtInSpeakerUID }) { return speakers }
            if let builtIn = devices.first(where: { $0.isBuiltIn }) { return builtIn }
            if let fallback = defaultOutputDevice(), let d = devices.first(where: { $0.id == fallback }) {
                return d
            }
            return devices[0]
        }
        if let exactUID = devices.first(where: { $0.uid == query }) { return exactUID }
        if let exactName = devices.first(where: { $0.name == query }) { return exactName }
        let needle = query.lowercased()
        if let partial = devices.first(where: { $0.name.lowercased().contains(needle) }) { return partial }
        if let partialUID = devices.first(where: { $0.uid.lowercased().contains(needle) }) { return partialUID }
        throw AudioDeviceError.notFound(query)
    }

    public static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Frames of latency between handing a buffer to the AUHAL and the sound
    /// leaving the DAC: the device's own latency, the HAL's safety offset and
    /// one IO buffer. Subtracting this is what makes `play_at_ns` mean "at
    /// the speaker" rather than "at the callback".
    public static func outputLatencyFrames(_ deviceID: AudioDeviceID) -> Int {
        let latency = uint32Property(deviceID, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput) ?? 0
        let safety = uint32Property(deviceID, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput) ?? 0
        let buffer = uint32Property(deviceID, kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeOutput)
            ?? uint32Property(deviceID, kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal)
            ?? 512
        // Stream latency is reported separately from device latency and is
        // non-zero on plenty of hardware; include it when the device has an
        // output stream that answers.
        let stream = firstOutputStreamLatency(deviceID) ?? 0
        return Int(latency) + Int(safety) + Int(buffer) + Int(stream)
    }

    public static func outputLatencyNanos(_ deviceID: AudioDeviceID, sampleRate: Double) -> UInt64 {
        let rate = sampleRate > 0 ? sampleRate : WireFormat.sampleRate
        return UInt64(Double(outputLatencyFrames(deviceID)) / rate * 1_000_000_000)
    }

    public static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        (uint32Property(deviceID, kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal) ?? 0) != 0
    }

    // MARK: - property helpers

    static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func uint32Property(_ deviceID: AudioDeviceID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        uint32Property(deviceID, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
    }

    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func firstOutputStreamLatency(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr,
              let first = streams.first else { return nil }
        return uint32Property(first, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal)
    }
}
