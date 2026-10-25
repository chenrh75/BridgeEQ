import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

enum AudioDeviceError: LocalizedError {
    case osStatus(OSStatus, String)
    case inputFormatUnavailable(String)
    case invalidRoute(String)
    var errorDescription: String? {
        switch self {
        case let .osStatus(status, operation):
            if status == kAudioUnitErr_FormatNotSupported {
                return "System audio and the selected output could not agree on an audio format. Choose headphones or a DAC, then try again."
            }
            return "\(operation) failed (Core Audio \(status))."
        case let .inputFormatUnavailable(name):
            return "The input device “\(name)” did not provide a usable audio format."
        case let .invalidRoute(message):
            return message
        }
    }
}

final class CoreAudioDevices {
    static func isPhysicalOutput(_ id: AudioDeviceID) -> Bool {
        guard let transport = uint32(id, kAudioDevicePropertyTransportType) else { return false }
        return transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate
    }
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func setDefaultOutputDeviceID(_ id: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = id
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        guard result == noErr else { throw AudioDeviceError.osStatus(result, "Change system output") }
        guard defaultOutputDeviceID() == id else {
            throw AudioDeviceError.invalidRoute("macOS did not switch to the selected output. Try selecting it again.")
        }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { throw AudioDeviceError.osStatus(status, "Read input sample rate") }
        return rate
    }
    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        let devices: [AudioDevice] = ids.compactMap { id in
            guard let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            guard !isPrivateAggregate(id, name: name) else { return nil }
            let inputChannels = channels(id, kAudioObjectPropertyScopeInput)
            let outputChannels = channels(id, kAudioObjectPropertyScopeOutput)
            return AudioDevice(id: id, uid: uid, name: name, inputChannels: inputChannels, outputChannels: outputChannels)
        }
        let usable = devices.filter { $0.inputChannels + $0.outputChannels > 0 }
        return usable.sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == ComparisonResult.orderedAscending
        }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func isPrivateAggregate(_ id: AudioObjectID, name: String) -> Bool {
        // Core Audio creates this process-private device while AVAudioEngine is
        // running. It is an implementation detail, not a route the user can
        // meaningfully select. Keep the name check as a fallback because some
        // OS versions omit the private flag from the composition dictionary.
        if name.hasPrefix("CADefaultDeviceAggregate-") { return true }
        guard uint32(id, kAudioObjectPropertyClass) == kAudioAggregateDeviceClassID,
              let composition = dictionary(id, kAudioAggregateDevicePropertyComposition) else { return false }
        if let isPrivate = composition[kAudioAggregateDeviceIsPrivateKey] as? Bool { return isPrivate }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func dictionary(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [String: Any]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as? [String: Any]
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

func selectOutputDevice(_ id: AudioDeviceID, on node: AVAudioOutputNode) throws {
    try selectDevice(id, audioUnit: node.audioUnit)
}

private func selectDevice(_ id: AudioDeviceID, audioUnit: AudioUnit?) throws {
    guard let audioUnit else { throw AudioDeviceError.osStatus(-1, "Access audio unit") }
    var device = id
    let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device)))
    guard status == noErr else { throw AudioDeviceError.osStatus(status, "Select device") }
}
