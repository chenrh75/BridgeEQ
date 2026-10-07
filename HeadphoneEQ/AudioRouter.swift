import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

private struct StereoMeterLevels {
    var leftPeak: Float = 0
    var rightPeak: Float = 0
    var leftRMS: Float = 0
    var rightRMS: Float = 0
}

private func measureLevels(_ buffer: AVAudioPCMBuffer) -> StereoMeterLevels {
    guard let data = buffer.floatChannelData else { return StereoMeterLevels() }
    let count = vDSP_Length(buffer.frameLength)
    guard count > 0 else { return StereoMeterLevels() }
    var levels = StereoMeterLevels()
    vDSP_maxmgv(data[0], 1, &levels.leftPeak, count)
    vDSP_rmsqv(data[0], 1, &levels.leftRMS, count)
    if buffer.format.channelCount > 1 {
        vDSP_maxmgv(data[1], 1, &levels.rightPeak, count)
        vDSP_rmsqv(data[1], 1, &levels.rightRMS, count)
    } else {
        levels.rightPeak = levels.leftPeak
        levels.rightRMS = levels.leftRMS
    }
    return levels
}

@MainActor
final class AudioRouter: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Stopped"
    let meters = MeterModel()

    private var inputCapture: HALInputCapture?
    private var outputEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var eq: AVAudioUnitEQ?
    private var gainMixer: AVAudioMixerNode?
    private var configObserver: NSObjectProtocol?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var meterTimer: Timer?
    private var routeInputDeviceID: AudioDeviceID?
    private var lastDefaultOutputDeviceID: AudioDeviceID?
    private let inputLevels = MeterAccumulator()
    private let outputLevels = MeterAccumulator()
    private var holdUntil = [TimeInterval](repeating: 0, count: 4)
    private var clipUntil = [TimeInterval](repeating: 0, count: 4)
    // The Float processing path has headroom above full scale. Only values that
    // actually exceed 0 dBFS are overs; near-full-scale legal samples are not.
    private static let clipThreshold: Float = 1.0
    private var ignoreConfigurationChangesUntil = Date.distantPast
    var onRecoveryNeeded: (() -> Void)?

    init() {
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.requestRecovery(reason: "Audio configuration changed; reconnecting…")
            }
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.checkSystemOutputChange()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            defaultOutputListener = listener
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let defaultOutputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultOutputListener)
        }
    }

    private func requestRecovery(reason: String) {
        guard (running || inputCapture != nil), Date() >= ignoreConfigurationChangesUntil else { return }
        status = reason
        running = false
        onRecoveryNeeded?()
    }

    private func checkSystemOutputChange() {
        guard let current = CoreAudioDevices.defaultOutputDeviceID(), current != lastDefaultOutputDeviceID else { return }
        lastDefaultOutputDeviceID = current
        guard current == routeInputDeviceID else { return }
        if Date() < ignoreConfigurationChangesUntil {
            let delay = ignoreConfigurationChangesUntil.timeIntervalSinceNow + 0.05
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(delay, 0.05)))
                guard let self, CoreAudioDevices.defaultOutputDeviceID() == self.routeInputDeviceID else { return }
                self.requestRecovery(reason: "BlackHole became system output; reconnecting…")
            }
            return
        }
        requestRecovery(reason: "BlackHole became system output; reconnecting…")
    }

    func start(input: AudioDevice, output: AudioDevice, preset: EQPreset) throws {
        stop()
        ignoreConfigurationChangesUntil = Date().addingTimeInterval(3)
        let outputEngine = AVAudioEngine()
        try selectOutputDevice(output.id, on: outputEngine.outputNode)

        let inputRate = try CoreAudioDevices.nominalSampleRate(input.id)
        guard let processingFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate,
                                                   channels: AVAudioChannelCount(min(input.inputChannels, 2))) else {
            throw AudioDeviceError.inputFormatUnavailable(input.name)
        }
        let eq = AVAudioUnitEQ(numberOfBands: max(preset.bands.count, 1))
        let mixer = AVAudioMixerNode()
        let player = AVAudioPlayerNode()
        outputEngine.attach(player); outputEngine.attach(eq); outputEngine.attach(mixer)
        outputEngine.connect(player, to: eq, format: processingFormat)
        outputEngine.connect(eq, to: mixer, format: processingFormat)
        outputEngine.connect(mixer, to: outputEngine.outputNode, format: nil)
        apply(preset, eq: eq, mixer: mixer)
        installMeter(on: mixer, bus: 0, input: false)
        outputEngine.prepare()
        do {
            try outputEngine.start()
            player.play()

            let capture = try HALInputCapture(deviceID: input.id, format: processingFormat, player: player, levels: inputLevels)
            try capture.start()
            self.inputCapture = capture; self.outputEngine = outputEngine; self.player = player
            self.eq = eq; self.gainMixer = mixer
            routeInputDeviceID = input.id
            lastDefaultOutputDeviceID = CoreAudioDevices.defaultOutputDeviceID()
            running = true; status = "Routing \(input.name) → \(output.name)"
            startMeterTimer()
        } catch {
            // A capture failure can happen after the output engine has started.
            // Tear down the partial route before allowing another start attempt.
            player.stop()
            outputEngine.stop()
            mixer.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        meterTimer?.invalidate(); meterTimer = nil
        gainMixer?.removeTap(onBus: 0)
        inputCapture?.stop(); player?.stop(); outputEngine?.stop()
        inputCapture = nil; outputEngine = nil; player = nil; eq = nil; gainMixer = nil
        routeInputDeviceID = nil; lastDefaultOutputDeviceID = nil
        _ = inputLevels.drain(); _ = outputLevels.drain()
        holdUntil = [TimeInterval](repeating: 0, count: 4)
        clipUntil = [TimeInterval](repeating: 0, count: 4)
        running = false; status = "Stopped"; meters.state = MeterState()
    }

    func update(_ preset: EQPreset) { if let eq, let gainMixer { apply(preset, eq: eq, mixer: gainMixer) } }

    private func apply(_ preset: EQPreset, eq: AVAudioUnitEQ, mixer: AVAudioMixerNode) {
        eq.globalGain = Float(preset.preamp)
        let hasAudibleBand = preset.bands.contains { band in
            guard band.enabled else { return false }
            switch band.type {
            case .lowPass, .highPass: return true
            case .parametric, .lowShelf, .highShelf: return abs(band.gain) > 0.0001
            }
        }
        eq.bypass = preset.globalBypass || (!hasAudibleBand && abs(preset.preamp) <= 0.0001)
        for (index, target) in eq.bands.enumerated() {
            guard index < preset.bands.count else { target.bypass = true; continue }
            let source = preset.bands[index]
            target.filterType = source.type.avType
            target.frequency = Float(source.frequency.clamped(to: 10...24000))
            target.gain = Float(source.gain.clamped(to: -24...24))
            // AVAudioUnitEQ expresses bandwidth in octaves; the UI and APO format use Q.
            let q = source.q.clamped(to: 0.1...20)
            target.bandwidth = Float(2 * asinh(1 / (2 * q)) / log(2))
            let isNeutralGainFilter = source.type != .lowPass && source.type != .highPass && abs(source.gain) <= 0.0001
            target.bypass = !source.enabled || isNeutralGainFilter
        }
        mixer.outputVolume = pow(10, Float(preset.outputGain) / 20)
    }

    private func installMeter(on node: AVAudioNode, bus: AVAudioNodeBus, input: Bool) {
        let accumulator = input ? inputLevels : outputLevels
        node.installTap(onBus: bus, bufferSize: 2048, format: nil) { buffer, _ in
            accumulator.accumulate(measureLevels(buffer))
        }
    }

    private func startMeterTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeters() }
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func updateMeters() {
        let input = inputLevels.drain()
        let output = outputLevels.drain()
        let previous = meters.state
        var meter = previous
        let now = ProcessInfo.processInfo.systemUptime

        updateMeterChannel(level: input.leftRMS, peak: input.leftPeak, reportsClip: false,
                           shown: &meter.inputLeft, hold: &meter.inputLeftHold,
                           holdUntil: &holdUntil[0], clipped: &meter.inputLeftClips, clipUntil: &clipUntil[0], now: now)
        updateMeterChannel(level: input.rightRMS, peak: input.rightPeak, reportsClip: false,
                           shown: &meter.inputRight, hold: &meter.inputRightHold,
                           holdUntil: &holdUntil[1], clipped: &meter.inputRightClips, clipUntil: &clipUntil[1], now: now)
        updateMeterChannel(level: output.leftRMS, peak: output.leftPeak, reportsClip: true,
                           shown: &meter.outputLeft, hold: &meter.outputLeftHold,
                           holdUntil: &holdUntil[2], clipped: &meter.outputLeftClips, clipUntil: &clipUntil[2], now: now)
        updateMeterChannel(level: output.rightRMS, peak: output.rightPeak, reportsClip: true,
                           shown: &meter.outputRight, hold: &meter.outputRightHold,
                           holdUntil: &holdUntil[3], clipped: &meter.outputRightClips, clipUntil: &clipUntil[3], now: now)
        if meter != previous { meters.state = meter }
    }

    private func updateMeterChannel(level: Float, peak: Float, reportsClip: Bool,
                                    shown: inout Float, hold: inout Float,
                                    holdUntil: inout TimeInterval, clipped: inout Bool,
                                    clipUntil: inout TimeInterval, now: TimeInterval) {
        shown = Self.meterBallistic(previous: shown, sample: level)
        if peak >= hold || now >= holdUntil {
            hold = max(peak, shown)
            holdUntil = now + 1.0
        }
        if reportsClip && peak > Self.clipThreshold { clipUntil = now + 1.0 }
        if !reportsClip { clipUntil = 0 }
        clipped = now < clipUntil
    }

    private static func meterBallistic(previous: Float, sample: Float) -> Float {
        if sample >= previous { return sample }
        return max(0.001, previous * 0.91201084) // Exactly 0.8 dB per frame at 30 Hz.
    }
}

@MainActor
final class MeterModel {
    var onUpdate: ((MeterState) -> Void)?
    var state = MeterState() {
        didSet { onUpdate?(state) }
    }
}

private final class MeterAccumulator: @unchecked Sendable {
    private let levels = OSAllocatedUnfairLock(initialState: StereoMeterLevels())

    func accumulate(_ incoming: StereoMeterLevels) {
        levels.withLock {
            $0.leftPeak = max($0.leftPeak, incoming.leftPeak)
            $0.rightPeak = max($0.rightPeak, incoming.rightPeak)
            $0.leftRMS = max($0.leftRMS, incoming.leftRMS)
            $0.rightRMS = max($0.rightRMS, incoming.rightRMS)
        }
    }

    func drain() -> StereoMeterLevels {
        levels.withLock {
            let result = $0
            $0 = StereoMeterLevels()
            return result
        }
    }
}

private final class HALInputCapture: @unchecked Sendable {
    private var unit: AudioUnit?
    private let format: AVAudioFormat
    private weak var player: AVAudioPlayerNode?
    private let levels: MeterAccumulator
    private let buffers = OSAllocatedUnfairLock(initialState: [AVAudioPCMBuffer]())

    init(deviceID: AudioDeviceID, format: AVAudioFormat, player: AVAudioPlayerNode,
         levels: MeterAccumulator) throws {
        self.format = format; self.player = player; self.levels = levels
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioDeviceError.osStatus(-1, "Find HAL audio unit") }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "Create HAL audio unit")
        guard let created else { throw AudioDeviceError.osStatus(-1, "Create HAL audio unit") }
        unit = created
        var enabled: UInt32 = 1, disabled: UInt32 = 0, device = deviceID
        try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, 4), "Enable HAL input")
        try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, 4), "Disable HAL output")
        try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, 4), "Select input device")
        var stream = format.streamDescription.pointee
        try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &stream, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set HAL capture format")
        var callback = AURenderCallbackStruct(inputProc: halInputCallback,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install HAL input callback")
        try check(AudioUnitInitialize(created), "Initialize HAL input")
        var maximumFrames: UInt32 = 4096
        var maximumFramesSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(created, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maximumFrames, &maximumFramesSize)
        let bufferFrameCapacity = maximumFrames
        buffers.withLock { pool in
            pool = (0..<16).compactMap { _ in
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrameCapacity)
            }
        }
    }

    func start() throws { guard let unit else { return }; try check(AudioOutputUnitStart(unit), "Start HAL input") }
    func stop() { if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }; unit = nil }
    deinit { stop() }

    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, let player, let buffer = acquireBuffer(for: frames) else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        guard status == noErr else {
            release(buffer)
            return status
        }
        levels.accumulate(measureLevels(buffer))
        player.scheduleBuffer(buffer) { [weak self] in self?.release(buffer) }
        return noErr
    }

    private func acquireBuffer(for frames: UInt32) -> AVAudioPCMBuffer? {
        buffers.withLock { pool in
            guard let buffer = pool.popLast() else { return nil }
            guard buffer.frameCapacity >= frames else {
                pool.append(buffer)
                return nil
            }
            return buffer
        }
    }

    private func release(_ buffer: AVAudioPCMBuffer) {
        buffer.frameLength = 0
        buffers.withLock { $0.append(buffer) }
    }
}

private func halInputCallback(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                              _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<HALInputCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags: flags, time: time, frames: frames)
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioDeviceError.osStatus(status, operation) }
}

private extension Comparable { func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) } }
