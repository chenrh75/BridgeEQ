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
                return "The selected devices could not agree on an audio format. Choose BlackHole as Input and headphones or a DAC as Output, then try again."
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
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
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

enum AggregateAudioDevice {
    static func create(input: AudioDevice, output: AudioDevice) throws -> AudioDeviceID {
        let uid = "com.example.HeadphoneEQ.\(UUID().uuidString)"
        let subdevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey: output.uid,
             kAudioSubDeviceDriftCompensationKey: false],
            [kAudioSubDeviceUIDKey: input.uid,
             kAudioSubDeviceDriftCompensationKey: true]
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Headphone EQ Private Route",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false
        ]
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr else { throw AudioDeviceError.osStatus(status, "Create private aggregate device") }
        return deviceID
    }

    static func destroy(_ deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(deviceID)
    }
}

func selectInputDevice(_ id: AudioDeviceID, on node: AVAudioInputNode) throws {
    try selectDevice(id, audioUnit: node.audioUnit)
}

func selectOutputDevice(_ id: AudioDeviceID, on node: AVAudioOutputNode) throws {
    try selectDevice(id, audioUnit: node.audioUnit)
}

func selectBlackHoleInputChannels(on node: AVAudioInputNode, physicalInputChannels: Int, virtualInputChannels: Int) throws {
    guard let audioUnit = node.audioUnit else { throw AudioDeviceError.osStatus(-1, "Access input audio unit") }
    var map = (0..<virtualInputChannels).map { Int32(physicalInputChannels + $0) }
    let status = map.withUnsafeBytes { bytes in
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, bytes.baseAddress, UInt32(bytes.count))
    }
    guard status == noErr else { throw AudioDeviceError.osStatus(status, "Select BlackHole input channels") }
}

private func selectDevice(_ id: AudioDeviceID, audioUnit: AudioUnit?) throws {
    guard let audioUnit else { throw AudioDeviceError.osStatus(-1, "Access audio unit") }
    var device = id
    let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device)))
    guard status == noErr else { throw AudioDeviceError.osStatus(status, "Select device") }
}
