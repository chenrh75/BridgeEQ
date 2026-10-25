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
    @Published private(set) var recovering = false
    @Published private(set) var status = "Stopped"
    let meters = MeterModel()

    private var directPath: DirectAudioPath?
    private var failedDirectOutputs = Set<String>()
    private var inputCapture: TapInputCapture?
    private var systemTap: SystemAudioTap?
    private var outputEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var eq: AVAudioUnitEQ?
    private var gainMixer: AVAudioMixerNode?
    private var configObserver: NSObjectProtocol?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var meterTimer: Timer?
    private var outputDeviceID: AudioDeviceID?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var lastDefaultOutputDeviceID: AudioDeviceID?
    private let inputLevels = MeterAccumulator(enabled: false)
    private let outputLevels = MeterAccumulator(enabled: false)
    private var meterTapInstalled = false
    private var meteringActive = false
    private var holdUntil = [TimeInterval](repeating: 0, count: 4)
    private var clipUntil = [TimeInterval](repeating: 0, count: 4)
    // The Float processing path has headroom above full scale. Only values that
    // actually exceed 0 dBFS are overs; near-full-scale legal samples are not.
    private static let clipThreshold: Float = 1.0
    private var ignoreConfigurationChangesUntil = Date.distantPast
    private var routeGeneration = 0
    var onRecoveryNeeded: (() -> Void)?
    var onSystemOutputChanged: ((AudioDeviceID) -> Void)?

    init() {
        lastDefaultOutputDeviceID = CoreAudioDevices.defaultOutputDeviceID()
        meters.onVisibilityChange = { [weak self] in self?.updateMeteringActivity() }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let engine = notification.object as? AVAudioEngine,
                      engine === self.outputEngine, Date() >= self.ignoreConfigurationChangesUntil else { return }
                self.requestRecovery(reason: "Audio configuration changed; reconnecting…")
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
        guard running else { return }
        if Date() < ignoreConfigurationChangesUntil {
            let delay = max(0.05, ignoreConfigurationChangesUntil.timeIntervalSinceNow + 0.05)
            let generation = routeGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.routeGeneration == generation else { return }
                self.requestRecovery(reason: reason)
            }
            return
        }
        beginRecovery()
        status = reason
        onRecoveryNeeded?()
    }

    func acknowledgeSystemOutputChange() {
        lastDefaultOutputDeviceID = CoreAudioDevices.defaultOutputDeviceID()
    }

    private func checkSystemOutputChange() {
        guard let current = CoreAudioDevices.defaultOutputDeviceID(), current != lastDefaultOutputDeviceID else { return }
        lastDefaultOutputDeviceID = current
        // Update the device preset even while stopped or waiting for a bound
        // output. The model decides whether the user has requested processing.
        onSystemOutputChanged?(current)
    }

    func start(output: AudioDevice, preset: EQPreset) throws {
        stop()
        guard CoreAudioDevices.isPhysicalOutput(output.id) else {
            throw AudioDeviceError.invalidRoute("Choose a physical output: headphones, speakers, or a DAC.")
        }
        ignoreConfigurationChangesUntil = Date().addingTimeInterval(3)
        if !failedDirectOutputs.contains(output.uid) {
            do {
                try startDirect(output: output, preset: preset)
                return
            } catch {
                // Unsupported layouts/rates and unavailable direct devices keep
                // the existing conversion and playback path.
            }
        }
        let outputEngine = AVAudioEngine()
        try selectOutputDevice(output.id, on: outputEngine.outputNode)

        // Start the engine first so Core Audio has a process object we can
        // exclude. Do not start reading/muting the tap before playback is ready.
        guard let processingFormat = AVAudioFormat(standardFormatWithSampleRate: try CoreAudioDevices.nominalSampleRate(output.id), channels: 2) else {
            throw AudioDeviceError.inputFormatUnavailable(output.name)
        }
        let eq = AVAudioUnitEQ(numberOfBands: max(preset.bands.count, 1))
        let mixer = AVAudioMixerNode()
        let player = AVAudioPlayerNode()
        outputEngine.attach(player); outputEngine.attach(eq); outputEngine.attach(mixer)
        outputEngine.connect(player, to: eq, format: processingFormat)
        outputEngine.connect(eq, to: mixer, format: processingFormat)
        outputEngine.connect(mixer, to: outputEngine.outputNode, format: nil)
        apply(preset, eq: eq, mixer: mixer)
        outputEngine.prepare()
        do {
            try outputEngine.start()
            player.play()

            let tap = try SystemAudioTap()
            if tap.format.sampleRate != processingFormat.sampleRate {
                // The tap can follow a different default output sample rate.
                // AVAudioEngine converts from its native rate to the output rate.
                outputEngine.pause()
                player.stop()
                outputEngine.disconnectNodeOutput(player)
                outputEngine.disconnectNodeOutput(eq)
                outputEngine.connect(player, to: eq, format: tap.format)
                outputEngine.connect(eq, to: mixer, format: tap.format)
                try outputEngine.start()
                player.play()
            }
            let capture = try TapInputCapture(tap: tap, player: player, levels: inputLevels)
            try capture.start()
            self.inputCapture = capture; self.outputEngine = outputEngine; self.player = player
            self.systemTap = tap
            self.eq = eq; self.gainMixer = mixer
            observeOutput(output.id)
            running = true; status = "System audio → \(output.name)"
            updateMeteringActivity()
        } catch {
            // A capture failure can happen after the output engine has started.
            // Tear down the partial route before allowing another start attempt.
            player.stop()
            outputEngine.stop()
            throw error
        }
    }

    private func startDirect(output: AudioDevice, preset: EQPreset) throws {
        guard output.inputChannels == 0, output.outputChannels == 2 else {
            throw AudioDeviceError.inputFormatUnavailable(output.name)
        }
        // A silent output client establishes our process object for exclusion
        // from the global tap. Keep it alive until the real IOProc is registered.
        var bootstrap: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcID(output.id, directBootstrapIO, nil, &bootstrap), "Prepare output")
        defer {
            if let bootstrap {
                AudioDeviceStop(output.id, bootstrap)
                AudioDeviceDestroyIOProcID(output.id, bootstrap)
            }
        }
        guard let bootstrap else { throw AudioDeviceError.inputFormatUnavailable(output.name) }
        try check(AudioDeviceStart(output.id, bootstrap), "Prepare system audio exclusion")
        let tap = try DirectSystemTap(output: output)
        let eq = AVAudioUnitEQ(numberOfBands: max(preset.bands.count, 1))
        apply(preset, eq: eq, mixer: nil)
        let path = try DirectAudioPath(tap: tap, eq: eq)
        path.setOutputGain(pow(10, Float(preset.outputGain) / 20), initial: true)
        path.onInput = { [inputLevels] in inputLevels.measure($0) }
        path.onOutput = { [outputLevels] in outputLevels.measure($0) }
        let generation = routeGeneration
        path.onFailure = { [weak self] in
            Task { @MainActor in
                guard let self, self.routeGeneration == generation else { return }
                self.failedDirectOutputs.insert(output.uid)
                self.beginRecovery()
                self.status = "Audio format changed; reconnecting…"
                self.onRecoveryNeeded?()
            }
        }
        try path.start()
        directPath = path
        self.eq = eq
        observeOutput(output.id)
        running = true; status = "System audio → \(output.name)"
        updateMeteringActivity()
    }

    private static let outputSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyStreamConfiguration
    ]

    private func observeOutput(_ id: AudioDeviceID) {
        outputDeviceID = id
        let generation = routeGeneration
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.routeGeneration == generation else { return }
                self.requestRecovery(reason: "Output device changed; reconnecting…")
            }
        }
        outputDeviceListener = listener
        for selector in Self.outputSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if selector == kAudioDevicePropertyStreamConfiguration { address.mScope = kAudioObjectPropertyScopeOutput }
            AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
        }
    }

    func beginRecovery() {
        stop()
        recovering = true
        status = "Reconnecting system audio…"
    }

    func stop() {
        routeGeneration += 1
        setMeteringActive(false)
        directPath?.stop(); directPath = nil
        inputCapture?.stop()
        player?.stop(); outputEngine?.stop()
        systemTap?.stop(); systemTap = nil
        if let id = outputDeviceID, let listener = outputDeviceListener {
            for selector in Self.outputSelectors {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                if selector == kAudioDevicePropertyStreamConfiguration { address.mScope = kAudioObjectPropertyScopeOutput }
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
            }
        }
        outputDeviceID = nil; outputDeviceListener = nil
        inputCapture = nil; outputEngine = nil; player = nil; eq = nil; gainMixer = nil
        // Retain the last system destination while reconnecting so changes
        // during the retry delay are still recognized as output switches.
        _ = inputLevels.drain(); _ = outputLevels.drain()
        holdUntil = [TimeInterval](repeating: 0, count: 4)
        clipUntil = [TimeInterval](repeating: 0, count: 4)
        running = false; recovering = false; status = "Stopped"; meters.state = MeterState()
    }

    func update(_ preset: EQPreset) {
        guard let eq else { return }
        if eq.bands.count != max(preset.bands.count, 1) {
            // AVAudioUnitEQ cannot resize its bands in place. Rebuild when
            // adding/deleting bands or loading a preset with a different size.
            beginRecovery()
            onRecoveryNeeded?()
            return
        }
        apply(preset, eq: eq, mixer: gainMixer)
        directPath?.setOutputGain(pow(10, Float(preset.outputGain) / 20))
    }

    private func apply(_ preset: EQPreset, eq: AVAudioUnitEQ, mixer: AVAudioMixerNode?) {
        eq.globalGain = Float(mixer == nil && preset.globalBypass ? 0 : preset.preamp)
        let hasAudibleBand = preset.bands.contains { band in
            guard band.enabled else { return false }
            switch band.type {
            case .lowPass, .highPass: return true
            case .parametric, .lowShelf, .highShelf: return abs(band.gain) > 0.0001
            }
        }
        // Node bypass belongs to AVAudioEngine. A standalone unit bypasses
        // individual bands and preamp instead.
        eq.bypass = mixer != nil && (preset.globalBypass || (!hasAudibleBand && abs(preset.preamp) <= 0.0001))
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
            target.bypass = (mixer == nil && preset.globalBypass) || !source.enabled || isNeutralGainFilter
        }
        mixer?.outputVolume = pow(10, Float(preset.outputGain) / 20)
    }

    private func updateMeteringActivity() {
        setMeteringActive(running && (directPath != nil || outputEngine?.isRunning == true) && meters.hasVisibleDisplay)
    }

    private func setMeteringActive(_ enabled: Bool) {
        guard enabled != meteringActive else { return }
        meteringActive = enabled
        meterTimer?.invalidate(); meterTimer = nil
        inputLevels.setEnabled(enabled); outputLevels.setEnabled(enabled)
        if enabled {
            holdUntil = [TimeInterval](repeating: 0, count: 4)
            clipUntil = [TimeInterval](repeating: 0, count: 4)
            meters.state = MeterState()
            if let gainMixer {
                let accumulator = outputLevels
                let generation = accumulator.generation
                gainMixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
                    accumulator.measure(buffer, expectedGeneration: generation)
                }
                meterTapInstalled = true
            }
            startMeterTimer()
        } else if meterTapInstalled {
            gainMixer?.removeTap(onBus: 0)
            meterTapInstalled = false
        }
    }

    private func startMeterTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updateMeters() }
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func updateMeters() {
        guard meteringActive else { return }
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
        // Deliver every visible tick so a throttled numeric label can catch up
        // even after the audio settles at an unchanged level.
        meters.state = meter
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
    var onVisibilityChange: (() -> Void)?
    private var visibleDisplays = Set<ObjectIdentifier>()
    var hasVisibleDisplay: Bool { !visibleDisplays.isEmpty }

    func setDisplayVisible(_ display: AnyObject, _ visible: Bool) {
        let previouslyVisible = hasVisibleDisplay
        if visible { visibleDisplays.insert(ObjectIdentifier(display)) }
        else { visibleDisplays.remove(ObjectIdentifier(display)) }
        if hasVisibleDisplay != previouslyVisible { onVisibilityChange?() }
    }
    var state = MeterState() {
        didSet { onUpdate?(state) }
    }
}

private final class MeterAccumulator: @unchecked Sendable {
    private struct State {
        var levels = StereoMeterLevels()
        var enabled: Bool
        var generation = 0
    }
    private let storage: OSAllocatedUnfairLock<State>

    init(enabled: Bool = true) {
        storage = OSAllocatedUnfairLock(initialState: State(enabled: enabled))
    }

    func setEnabled(_ enabled: Bool) {
        storage.withLock {
            $0.enabled = enabled
            $0.generation += 1
            $0.levels = StereoMeterLevels()
        }
    }

    var generation: Int { storage.withLock { $0.generation } }

    func measure(_ buffer: AVAudioPCMBuffer, expectedGeneration: Int? = nil) {
        let generation = storage.withLock { state -> Int? in
            guard state.enabled, expectedGeneration == nil || expectedGeneration == state.generation else { return nil }
            return state.generation
        }
        guard let generation else { return }
        let incoming = measureLevels(buffer)
        storage.withLock {
            // A callback already in flight when the window hid must not
            // republish old peaks after a subsequent resume.
            guard $0.enabled, $0.generation == generation else { return }
            Self.merge(incoming, into: &$0.levels)
        }
    }

    func accumulate(_ incoming: StereoMeterLevels) {
        storage.withLock {
            guard $0.enabled else { return }
            Self.merge(incoming, into: &$0.levels)
        }
    }

    private static func merge(_ incoming: StereoMeterLevels, into levels: inout StereoMeterLevels) {
        levels.leftPeak = max(levels.leftPeak, incoming.leftPeak)
        levels.rightPeak = max(levels.rightPeak, incoming.rightPeak)
        levels.leftRMS = max(levels.leftRMS, incoming.leftRMS)
        levels.rightRMS = max(levels.rightRMS, incoming.rightRMS)
    }

    func drain() -> StereoMeterLevels {
        storage.withLock {
            let result = $0.levels
            $0.levels = StereoMeterLevels()
            return result
        }
    }
}

// Owns the tap and its private input-only aggregate. The aggregate is never
// selected as macOS output and disappears when the route ends.
private final class SystemAudioTap {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private(set) var format: AVAudioFormat!
    private(set) var sourceFormat = AudioStreamBasicDescription()

    init() throws {
        do {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = getpid()
            var processID = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processID), "Find BridgeEQ audio process")
            guard processID != kAudioObjectUnknown else {
                throw AudioDeviceError.invalidRoute("Could not exclude BridgeEQ from system capture. Restart the app and try again.")
            }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [processID])
            description.name = "BridgeEQ System Audio"
            description.isPrivate = true
            // Unlike unconditional mute, this restores ordinary playback when
            // the input client stops, including startup failures.
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Create system audio tap")

            address.mSelector = kAudioTapPropertyFormat
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &sourceFormat), "Read system audio format")
            guard sourceFormat.mFormatID == kAudioFormatLinearPCM,
                  sourceFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  sourceFormat.mBitsPerChannel == 32, sourceFormat.mChannelsPerFrame == 2,
                  sourceFormat.mSampleRate > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: sourceFormat.mSampleRate, channels: 2) else {
                throw AudioDeviceError.invalidRoute("System audio did not provide a supported stereo Float32 format.")
            }
            self.format = format
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "BridgeEQ Private System Capture",
                kAudioAggregateDeviceUIDKey: "com.local.BridgeEQ.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                // Do not wait for another app to play before Start returns.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID),
                      "Create private system audio route")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}

private final class TapInputCapture: @unchecked Sendable {
    private let tap: SystemAudioTap
    private var ioProc: AudioDeviceIOProcID?
    private let player: AVAudioPlayerNode
    private let interleaved: Bool
    private let levels: MeterAccumulator
    private let buffers = OSAllocatedUnfairLock(initialState: [AVAudioPCMBuffer]())

    init(tap: SystemAudioTap, player: AVAudioPlayerNode, levels: MeterAccumulator) throws {
        self.tap = tap; self.player = player; self.levels = levels
        interleaved = tap.sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        // Preallocate a bounded pool; avoid allocating PCM storage in the callback.
        buffers.withLock { pool in
            pool = (0..<16).compactMap { _ in AVAudioPCMBuffer(pcmFormat: tap.format, frameCapacity: 16384) }
        }
        try check(AudioDeviceCreateIOProcID(tap.deviceID, tapInputCallback,
            Unmanaged.passUnretained(self).toOpaque(), &ioProc), "Prepare system audio capture")
    }

    func start() throws {
        guard let ioProc else { throw AudioDeviceError.invalidRoute("System audio capture was not initialized.") }
        let result = AudioDeviceStart(tap.deviceID, ioProc)
        guard result == noErr else {
            throw AudioDeviceError.invalidRoute("Could not start system audio capture (Core Audio \(result)). Allow BridgeEQ in System Settings → Privacy & Security → Screen & System Audio Recording, then restart BridgeEQ.")
        }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(tap.deviceID, ioProc)
            AudioDeviceDestroyIOProcID(tap.deviceID, ioProc)
        }
        ioProc = nil
    }

    deinit { stop() }

    fileprivate func render(_ input: UnsafePointer<AudioBufferList>) -> OSStatus {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let requiredBuffers = interleaved ? 1 : 2
        guard source.count == requiredBuffers, let first = source.first,
              first.mNumberChannels == (interleaved ? 2 : 1),
              first.mData != nil, first.mDataByteSize > 0 else { return noErr }
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * (interleaved ? 2 : 1))
        let frames = first.mDataByteSize / bytesPerFrame
        guard frames > 0 else { return noErr }
        guard let buffer = acquireBuffer(for: frames), let destination = buffer.floatChannelData else {
            return noErr
        }
        buffer.frameLength = frames
        if interleaved {
            let samples = first.mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(frames) {
                destination[0][index] = samples[index * 2]
                destination[1][index] = samples[index * 2 + 1]
            }
        } else {
            for channel in 0..<2 {
                guard let data = source[channel].mData,
                      source[channel].mNumberChannels == 1,
                      source[channel].mDataByteSize >= frames * UInt32(MemoryLayout<Float>.size) else {
                    release(buffer)
                    return noErr
                }
                memcpy(destination[channel], data, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        levels.measure(buffer)
        // The completion needs only the pool, not a weak load of the capture
        // object on every audio callback. The pool remains alive until all
        // queued completions finish, without retaining the player or capture.
        player.scheduleBuffer(buffer) { [buffers] in
            buffer.frameLength = 0
            buffers.withLock { $0.append(buffer) }
        }
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

private func tapInputCallback(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                             _ input: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>,
                             _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: UnsafePointer<AudioTimeStamp>,
                             _ refCon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let refCon else { return noErr }
    return Unmanaged<TapInputCapture>.fromOpaque(refCon).takeUnretainedValue().render(input)
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioDeviceError.osStatus(status, operation) }
}

private extension Comparable { func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) } }
