import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

private func verify(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else { throw AudioDeviceError.osStatus(status, message) }
}

func directBootstrapIO(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                   _ input: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>,
                   _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: UnsafePointer<AudioTimeStamp>,
                   _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    for buffer in UnsafeMutableAudioBufferListPointer(output) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    return noErr
}

final class DirectSystemTap {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var deviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var tapFormat = AudioStreamBasicDescription()
    let sampleRate: Double

    init(output: AudioDevice) throws {
        // With no hardware inputs the aggregate input is exactly the stereo tap.
        // Other device layouts use the converting AVAudioEngine route.
        guard output.inputChannels == 0, output.outputChannels == 2 else {
            throw AudioDeviceError.invalidRoute("Direct routing requires a stereo output-only device.")
        }
        sampleRate = try CoreAudioDevices.nominalSampleRate(output.id)
        do {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = getpid()
            var process = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try verify(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Find process")
            guard process != kAudioObjectUnknown else { throw AudioDeviceError.invalidRoute("No own audio process") }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [process])
            description.name = "BridgeEQ System Audio"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try verify(AudioHardwareCreateProcessTap(description, &tapID), "Create tap")
            address.mSelector = kAudioTapPropertyFormat
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try verify(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &tapFormat), "Tap format")
            guard tapFormat.mFormatID == kAudioFormatLinearPCM,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  tapFormat.mBitsPerChannel == 32, tapFormat.mChannelsPerFrame == 2,
                  tapFormat.mSampleRate == sampleRate,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  tapFormat.mBytesPerFrame == (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 4 : 8) else {
                throw AudioDeviceError.invalidRoute("Unsupported direct tap format")
            }
            var outputFormat = AudioStreamBasicDescription()
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try verify(AudioObjectGetPropertyData(output.id, &address, 0, nil, &size, &outputFormat), "Output format")
            guard outputFormat.mFormatID == kAudioFormatLinearPCM,
                  outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  outputFormat.mBitsPerChannel == 32, outputFormat.mChannelsPerFrame == 2,
                  outputFormat.mSampleRate == sampleRate,
                  outputFormat.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  outputFormat.mBytesPerFrame == (outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 4 : 8) else {
                throw AudioDeviceError.invalidRoute("Unsupported direct output format")
            }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "BridgeEQ Direct Private Route",
                kAudioAggregateDeviceUIDKey: "com.local.BridgeEQ.direct.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                 kAudioSubTapDriftCompensationKey: true]]
            ]
            try verify(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID), "Create duplex aggregate")
            guard try CoreAudioDevices.nominalSampleRate(deviceID) == sampleRate else {
                throw AudioDeviceError.invalidRoute("Direct route clock does not match output")
            }
        } catch { stop(); throw error }
    }

    func stop() {
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID); deviceID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }
    deinit { stop() }
}

final class DirectAudioPath: @unchecked Sendable {
    let tap: DirectSystemTap
    let eq: AVAudioUnitEQ
    let input: AVAudioPCMBuffer
    let result: AVAudioPCMBuffer
    private var ioProc: AudioDeviceIOProcID?
    // Main-thread updates never block the real-time thread: it keeps the last
    // target if the tiny control lock is temporarily held.
    private let gain = OSAllocatedUnfairLock(initialState: Float(1))
    private var targetGain: Float = 1
    private var currentGain: Float = 1
    private var gainStep: Float = 0
    private var rampRemaining = 0
    private var failed = false // Owned by the device callback.
    var onFailure: (() -> Void)?

    func setOutputGain(_ value: Float, initial: Bool = false) {
        gain.withLock { $0 = value }
        if initial { targetGain = value; currentGain = value }
    }

    var onInput: ((AVAudioPCMBuffer) -> Void)?
    var onOutput: ((AVAudioPCMBuffer) -> Void)?

    init(tap: DirectSystemTap, eq: AVAudioUnitEQ) throws {
        self.tap = tap
        self.eq = eq
        let format = AVAudioFormat(standardFormatWithSampleRate: tap.sampleRate, channels: 2)!
        input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384)!
        result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384)!
        do {
            AudioUnitUninitialize(eq.audioUnit)
            var stream = format.streamDescription.pointee
            try verify(AudioUnitSetProperty(eq.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                0, &stream, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "EQ input")
            try verify(AudioUnitSetProperty(eq.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                0, &stream, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "EQ output")
            var maximumFrames: UInt32 = 16384
            try verify(AudioUnitSetProperty(eq.audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
                0, &maximumFrames, UInt32(MemoryLayout<UInt32>.size)), "EQ slice size")
            var callback = AURenderCallbackStruct(inputProc: directInput, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try verify(AudioUnitSetProperty(eq.audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "EQ callback")
            try verify(AudioUnitInitialize(eq.audioUnit), "Initialize EQ")
            try verify(AudioDeviceCreateIOProcID(tap.deviceID, directIO, Unmanaged.passUnretained(self).toOpaque(), &ioProc), "Direct IO callback")
        } catch {
            AudioUnitUninitialize(eq.audioUnit)
            throw error
        }
    }

    func start() throws {
        guard let ioProc else { throw AudioDeviceError.invalidRoute("Direct route was not initialized.") }
        try verify(AudioDeviceStart(tap.deviceID, ioProc), "Start direct route")
    }
    func stop() {
        if let ioProc {
            AudioDeviceStop(tap.deviceID, ioProc)
            AudioDeviceDestroyIOProcID(tap.deviceID, ioProc)
        }
        ioProc = nil
    }
    deinit { stop(); AudioUnitUninitialize(eq.audioUnit) }

    func render(_ source: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, _ timestamp: UnsafePointer<AudioTimeStamp>) -> OSStatus {
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard !failed else { return noErr }
        guard let firstOut = outputs.first,
              (outputs.count == 1 && firstOut.mNumberChannels == 2) ||
              (outputs.count == 2 && outputs.allSatisfy({ $0.mNumberChannels == 1 })) else { return fail() }
        let frameBytes = 4 * firstOut.mNumberChannels
        guard firstOut.mDataByteSize % frameBytes == 0 else { return fail() }
        let frames = firstOut.mDataByteSize / frameBytes
        if frames == 0 { return noErr }
        guard frames <= input.frameCapacity,
              outputs.allSatisfy({ $0.mData != nil && $0.mDataByteSize == frames * 4 * $0.mNumberChannels }) else { return fail() }
        let planar = tap.tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard sources.count == (planar ? 2 : 1) else { return fail() }
        input.frameLength = frames
        result.frameLength = frames
        let destination = input.floatChannelData!
        let processed = result.floatChannelData!
        if planar {
            for channel in 0..<2 {
                let buffer = sources[channel]
                guard buffer.mNumberChannels == 1 else { return fail() }
                if let data = buffer.mData, buffer.mDataByteSize > 0 {
                    guard buffer.mDataByteSize == frames * 4 else { return fail() }
                    memcpy(destination[channel], data, Int(frames) * 4)
                } else {
                    memset(destination[channel], 0, Int(frames) * 4)
                }
            }
        } else {
            let buffer = sources[0]
            guard buffer.mNumberChannels == 2 else { return fail() }
            if let data = buffer.mData, buffer.mDataByteSize > 0 {
                guard buffer.mDataByteSize == frames * 8 else { return fail() }
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<Int(frames) {
                    destination[0][index] = samples[index * 2]
                    destination[1][index] = samples[index * 2 + 1]
                }
            } else {
                memset(destination[0], 0, Int(frames) * 4)
                memset(destination[1], 0, Int(frames) * 4)
            }
        }
        onInput?(input)
        var flags = AudioUnitRenderActionFlags()
        let error = AudioUnitRender(eq.audioUnit, &flags, timestamp, 0, frames, result.mutableAudioBufferList)
        guard error == noErr else { return fail() }
        // Preserve output gain after the filters, including during bypass.
        // A short ramp avoids discontinuities when the volume slider moves.
        if let value = gain.withLockIfAvailable({ $0 }), value != targetGain {
            targetGain = value
            rampRemaining = max(1, Int(tap.sampleRate * 0.005))
            gainStep = (targetGain - currentGain) / Float(rampRemaining)
        }
        let rampFrames = min(rampRemaining, Int(frames))
        for index in 0..<rampFrames {
            currentGain += gainStep
            processed[0][index] *= currentGain
            processed[1][index] *= currentGain
        }
        rampRemaining -= rampFrames
        if rampRemaining == 0 { currentGain = targetGain }
        if rampFrames < Int(frames) && currentGain != 1 {
            var scale = currentGain
            for channel in 0..<2 {
                vDSP_vsmul(processed[channel] + rampFrames, 1, &scale,
                           processed[channel] + rampFrames, 1, vDSP_Length(Int(frames) - rampFrames))
            }
        }
        onOutput?(result)
        if outputs.count >= 2 && outputs[0].mNumberChannels == 1 && outputs[1].mNumberChannels == 1 {
            for channel in 0..<2 {
                guard let data = outputs[channel].mData, outputs[channel].mDataByteSize >= frames * 4 else { return fail() }
                memcpy(data, processed[channel], Int(frames) * 4)
            }
        } else if outputs.count == 1 && firstOut.mNumberChannels == 2, let data = firstOut.mData {
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(frames) {
                samples[index * 2] = processed[0][index]
                samples[index * 2 + 1] = processed[1][index]
            }
        } else { return fail() }
        return noErr
    }
    private func fail() -> OSStatus {
        // The callback only reports once. The owner joins this IOProc before
        // releasing its buffers and recreates the route through the fallback.
        failed = true
        onFailure?()
        return noErr
    }

}

private func directInput(_ refcon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                         _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return kAudio_ParamError }
    let core = Unmanaged<DirectAudioPath>.fromOpaque(refcon).takeUnretainedValue()
    guard frames <= core.input.frameLength else { return kAudioUnitErr_TooManyFramesToProcess }
    data.pointee.mNumberBuffers = 2
    let target = UnsafeMutableAudioBufferListPointer(data)
    for channel in 0..<2 {
        target[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: core.input.floatChannelData![channel])
    }
    return noErr
}

private func directIO(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                      _ input: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>,
                      _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: UnsafePointer<AudioTimeStamp>,
                      _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let refcon else { return noErr }
    return Unmanaged<DirectAudioPath>.fromOpaque(refcon).takeUnretainedValue().render(input, output, outputTime)
}
