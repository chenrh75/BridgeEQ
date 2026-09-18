import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

@MainActor
final class AudioRouter: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var meter = MeterState()

    private var inputCapture: HALInputCapture?
    private var outputEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var eq: AVAudioUnitEQ?
    private var gainMixer: AVAudioMixerNode?
    private var configObserver: NSObjectProtocol?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var meterTimer: Timer?
    private var systemOutputTimer: Timer?
    private var routeInputDeviceID: AudioDeviceID?
    private var lastDefaultOutputDeviceID: AudioDeviceID?
    private var latestInputLeft: Float = 0, latestInputRight: Float = 0
    private var latestOutputLeft: Float = 0, latestOutputRight: Float = 0
    private var holdUntil = [TimeInterval](repeating: 0, count: 4)
    private var clipUntil = [TimeInterval](repeating: 0, count: 4)
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

    private func startSystemOutputMonitor() {
        systemOutputTimer?.invalidate()
        systemOutputTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSystemOutputChange() }
        }
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
        try outputEngine.start()
        player.play()

        let capture = try HALInputCapture(deviceID: input.id, format: processingFormat, player: player) { [weak self] left, right in
            Task { @MainActor in
                self?.latestInputLeft = max(self?.latestInputLeft ?? 0, left)
                self?.latestInputRight = max(self?.latestInputRight ?? 0, right)
            }
        }
        try capture.start()
        self.inputCapture = capture; self.outputEngine = outputEngine; self.player = player
        self.eq = eq; self.gainMixer = mixer
        routeInputDeviceID = input.id
        lastDefaultOutputDeviceID = CoreAudioDevices.defaultOutputDeviceID()
        running = true; status = "Routing \(input.name) → \(output.name)"
        startMeterTimer()
        startSystemOutputMonitor()
    }

    func stop() {
        meterTimer?.invalidate(); meterTimer = nil
        systemOutputTimer?.invalidate(); systemOutputTimer = nil
        gainMixer?.removeTap(onBus: 0)
        inputCapture?.stop(); player?.stop(); outputEngine?.stop()
        inputCapture = nil; outputEngine = nil; player = nil; eq = nil; gainMixer = nil
        routeInputDeviceID = nil; lastDefaultOutputDeviceID = nil
        running = false; status = "Stopped"; meter = MeterState()
    }

    func update(_ preset: EQPreset) { if let eq, let gainMixer { apply(preset, eq: eq, mixer: gainMixer) } }

    private func apply(_ preset: EQPreset, eq: AVAudioUnitEQ, mixer: AVAudioMixerNode) {
        eq.globalGain = Float(preset.preamp)
        eq.bypass = preset.globalBypass
        for (index, target) in eq.bands.enumerated() {
            guard index < preset.bands.count else { target.bypass = true; continue }
            let source = preset.bands[index]
            target.filterType = source.type.avType
            target.frequency = Float(source.frequency.clamped(to: 10...24000))
            target.gain = Float(source.gain.clamped(to: -24...24))
            // AVAudioUnitEQ expresses bandwidth in octaves; the UI and APO format use Q.
            let q = source.q.clamped(to: 0.1...20)
            target.bandwidth = Float(2 * asinh(1 / (2 * q)) / log(2))
            target.bypass = !source.enabled
        }
        mixer.outputVolume = pow(10, Float(preset.outputGain) / 20)
    }

    private func installMeter(on node: AVAudioNode, bus: AVAudioNodeBus, input: Bool) {
        node.installTap(onBus: bus, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let peaks = Self.channelPeaks(buffer)
            Task { @MainActor in
                guard let self else { return }
                if input {
                    self.latestInputLeft = max(self.latestInputLeft, peaks.0)
                    self.latestInputRight = max(self.latestInputRight, peaks.1)
                } else {
                    self.latestOutputLeft = max(self.latestOutputLeft, peaks.0)
                    self.latestOutputRight = max(self.latestOutputRight, peaks.1)
                }
            }
        }
    }

    private static func channelPeaks(_ buffer: AVAudioPCMBuffer) -> (Float, Float) {
        guard let data = buffer.floatChannelData else { return (0, 0) }
        var left: Float = 0, right: Float = 0
        for i in 0..<Int(buffer.frameLength) { left = max(left, abs(data[0][i])) }
        if buffer.format.channelCount > 1 {
            for i in 0..<Int(buffer.frameLength) { right = max(right, abs(data[1][i])) }
        } else { right = left }
        return (left, right)
    }

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let samples = [self.latestInputLeft, self.latestInputRight, self.latestOutputLeft, self.latestOutputRight]
                self.latestInputLeft = 0; self.latestInputRight = 0; self.latestOutputLeft = 0; self.latestOutputRight = 0
                let old = [self.meter.inputLeft, self.meter.inputRight, self.meter.outputLeft, self.meter.outputRight]
                let oldHolds = [self.meter.inputLeftHold, self.meter.inputRightHold, self.meter.outputLeftHold, self.meter.outputRightHold]
                let now = ProcessInfo.processInfo.systemUptime
                var shown = [Float](repeating: 0, count: 4), holds = oldHolds, clips = [Bool](repeating: false, count: 4)
                for index in 0..<4 {
                    shown[index] = Self.meterBallistic(previous: old[index], sample: samples[index])
                    if samples[index] >= holds[index] || now >= self.holdUntil[index] {
                        holds[index] = max(samples[index], shown[index]); self.holdUntil[index] = now + 1.0
                    }
                    if samples[index] >= 0.999 { self.clipUntil[index] = now + 1.0 }
                    clips[index] = now < self.clipUntil[index]
                }
                self.meter = MeterState(inputLeft: shown[0], inputRight: shown[1], outputLeft: shown[2], outputRight: shown[3],
                                        inputLeftHold: holds[0], inputRightHold: holds[1], outputLeftHold: holds[2], outputRightHold: holds[3],
                                        inputLeftClips: clips[0], inputRightClips: clips[1], outputLeftClips: clips[2], outputRightClips: clips[3])
            }
        }
    }

    private static func meterBallistic(previous: Float, sample: Float) -> Float {
        if sample >= previous { return sample }
        let previousDB = 20 * log10(max(previous, 0.001))
        return pow(10, max(-60, previousDB - 0.4) / 20) // 24 dB/second release at 60 Hz.
    }
}

private final class HALInputCapture: @unchecked Sendable {
    private var unit: AudioUnit?
    private let format: AVAudioFormat
    private weak var player: AVAudioPlayerNode?
    private let onPeak: @Sendable (Float, Float) -> Void
    private let lock = NSLock()
    private var queued = 0

    init(deviceID: AudioDeviceID, format: AVAudioFormat, player: AVAudioPlayerNode,
         onPeak: @escaping @Sendable (Float, Float) -> Void) throws {
        self.format = format; self.player = player; self.onPeak = onPeak
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
    }

    func start() throws { guard let unit else { return }; try check(AudioOutputUnitStart(unit), "Start HAL input") }
    func stop() { if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }; unit = nil }
    deinit { stop() }

    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, let player, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        var left: Float = 0, right: Float = 0
        if let data = buffer.floatChannelData {
            for i in 0..<Int(frames) { left = max(left, abs(data[0][i])) }
            if buffer.format.channelCount > 1 { for i in 0..<Int(frames) { right = max(right, abs(data[1][i])) } } else { right = left }
        }
        onPeak(left, right)
        lock.lock(); let accept = queued < 12; if accept { queued += 1 }; lock.unlock()
        if accept {
            player.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }; self.lock.lock(); self.queued = max(0, self.queued - 1); self.lock.unlock()
            }
        }
        return noErr
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
