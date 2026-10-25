// Compile with AppModel.swift and Models.swift. These doubles exercise the
// actual app model without capturing audio or changing real device settings.
import Foundation
import SwiftUI

enum CoreAudioDevices {
    static let headphones = AudioDevice(id: 1, uid: "headphones", name: "Headphones", inputChannels: 0, outputChannels: 2)
    static let speakers = AudioDevice(id: 2, uid: "speakers", name: "Speakers", inputChannels: 0, outputChannels: 2)
    static let otherHeadphones = AudioDevice(id: 3, uid: "other-headphones", name: "Headphones", inputChannels: 0, outputChannels: 2)
    static var available = [headphones, speakers, otherHeadphones]
    static var currentDefaultUID = "headphones"
    static var rejectOutputChange = false
    static var outputWrites: [UInt32] = []
    static func all() -> [AudioDevice] { available }
    static func isPhysicalOutput(_ id: UInt32) -> Bool { available.contains { $0.id == id } }
    static func defaultOutputDeviceID() -> UInt32? { available.first { $0.uid == currentDefaultUID }?.id }
    static func setDefaultOutputDeviceID(_ id: UInt32) throws {
        if rejectOutputChange { throw NSError(domain: "Test", code: 1) }
        outputWrites.append(id)
        currentDefaultUID = available.first { $0.id == id }!.uid
    }
}

@MainActor
final class AudioRouter {
    var running = false
    var recovering = false
    var status = "Stopped"
    var meters = TestMeters()
    var onRecoveryNeeded: (() -> Void)?
    private var systemOutputHandler: ((UInt32) -> Void)?
    var onSystemOutputChanged: ((UInt32) -> Void)? {
        get {
            guard let handler = systemOutputHandler else { return nil }
            return { id in
                try! CoreAudioDevices.setDefaultOutputDeviceID(id)
                handler(id)
            }
        }
        set { systemOutputHandler = newValue }
    }
    func acknowledgeSystemOutputChange() {}
    var starts: [(String, EQPreset)] = []
    func update(_ preset: EQPreset) {}
    func start(output: AudioDevice, preset: EQPreset) throws {
        starts.append((output.uid, preset))
        running = true; recovering = false
    }
    func stop() { running = false; recovering = false }
    func beginRecovery() { stop(); recovering = true }
}

struct TestMeters { var state = MeterState() }

@main
struct DevicePresetTests {
    @MainActor
    static func main() async throws {
        let suite = "BridgeEQ.DevicePresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.preset = EQPreset(name: "Headphone EQ", preamp: -6, bands: [])
        model.savePreset(named: "Headphone EQ")
        let headphoneID = model.preset.id
        model.setPresetBoundToOutput(true)
        precondition(model.presetIsBoundToOutput)
        model.preset.preamp = -7

        let restored = AppModel(defaults: defaults)
        precondition(restored.presetIsBoundToOutput && restored.preset.preamp == -7)
        precondition(!restored.processingRequested && !restored.router.running)

        model.toggle()
        precondition(model.router.running)
        model.router.onSystemOutputChanged?(2)
        precondition(model.outputUID == "speakers" && !model.router.running)
        precondition(model.processingRequested && !model.router.recovering)
        precondition(!model.presetIsBoundToOutput)

        model.router.onSystemOutputChanged?(1)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == headphoneID)
        precondition(model.router.starts.last?.0 == "headphones")

        model.toggle() // Explicit Stop disables automatic resume.
        model.selectOutput("speakers")
        model.preset = EQPreset(name: "Speaker EQ", preamp: -2, bands: [])
        model.savePreset(named: "Speaker EQ")
        model.setPresetBoundToOutput(true)
        let speakerID = model.preset.id
        model.toggle()
        model.selectOutput("headphones")
        precondition(model.preset.id == headphoneID && model.router.recovering)
        model.selectOutput("speakers") // Replace the pending headphone retry.
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == speakerID)
        precondition(model.router.starts.last?.0 == "speakers")
        precondition(!model.router.starts.suffix(1).contains { $0.0 == "headphones" })

        model.savePreset(named: "Speaker EQ")
        precondition(model.preset.id == speakerID && model.presetIsBoundToOutput)
        model.toggle()
        let startCount = model.router.starts.count
        model.router.onSystemOutputChanged?(1)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(!model.processingRequested && !model.router.running)
        precondition(model.router.starts.count == startCount)
        precondition(model.preset.id == headphoneID)

        model.setPresetBoundToOutput(false)
        precondition(!model.presetIsBoundToOutput)
        let unbound = AppModel(defaults: defaults)
        precondition(!unbound.presetIsBoundToOutput)
        model.selectOutput("speakers")
        model.deletePreset(model.preset)
        precondition(model.devicePresets.isEmpty)

        // Save As on one device must not rename another device's binding.
        model.selectOutput("headphones")
        model.load(model.presets.first { $0.id == headphoneID }!)
        model.setPresetBoundToOutput(true)
        model.selectOutput("speakers")
        model.load(model.presets.first { $0.id == headphoneID }!)
        model.setPresetBoundToOutput(true)
        model.savePreset(named: "Speaker copy")
        precondition(model.devicePresets["headphones"]?.id == headphoneID)
        precondition(model.devicePresets["speakers"]?.id == model.preset.id)
        precondition(model.preset.id != headphoneID)
        print("DEVICE_PRESET_TESTS_PASSED")
        try await testIdenticalDeviceNames()
        testSharedDeviceIdentity()
        try await testGlobalPresets()
        try await testNoEQOutputs()
        try await testOutputSynchronizationAndExplicitGlobal()
        try await testDelayedSystemOutputChanges()
    }

    @MainActor
    static func testIdenticalDeviceNames() async throws {
        CoreAudioDevices.currentDefaultUID = "headphones"
        let suite = "BridgeEQ.SameNameTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let originalDevices = CoreAudioDevices.available
        defer {
            defaults.removePersistentDomain(forName: suite)
            CoreAudioDevices.available = originalDevices
        }
        let model = AppModel(defaults: defaults)
        precondition(CoreAudioDevices.headphones.name == CoreAudioDevices.otherHeadphones.name)
        model.preset = EQPreset(name: "First headphone EQ", preamp: -8, bands: [])
        model.savePreset(named: "First headphone EQ")
        let firstID = model.preset.id
        model.setPresetBoundToOutput(true)
        model.toggle()

        // Identical display names must not inherit the first device's EQ.
        model.router.onSystemOutputChanged?(3)
        precondition(model.selectedOutput?.id == 3 && !model.presetIsBoundToOutput)
        precondition(!model.router.running && !model.router.recovering)
        model.load(EQPreset(name: "Second headphone EQ", preamp: -2, bands: []))
        model.savePreset(named: "Second headphone EQ")
        let secondID = model.preset.id
        model.setPresetBoundToOutput(true)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.router.starts.last?.0 == "other-headphones")
        precondition(model.router.starts.last?.1.id == secondID)
        model.router.onSystemOutputChanged?(1)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.preset.id == firstID && model.preset.preamp == -8)
        precondition(model.router.starts.last?.0 == "headphones")
        precondition(model.router.starts.last?.1.id == firstID)
        model.toggle()

        // Reconnection may assign new numeric IDs. Persistent UIDs must still
        // select the right binding after a restart, even with reversed ordering.
        CoreAudioDevices.available = [
            AudioDevice(id: 103, uid: "other-headphones", name: "Headphones", inputChannels: 0, outputChannels: 2),
            AudioDevice(id: 101, uid: "headphones", name: "Headphones", inputChannels: 0, outputChannels: 2)
        ]
        let restored = AppModel(defaults: defaults)
        precondition(restored.selectedOutput?.id == 101 && restored.preset.id == firstID)
        restored.router.onSystemOutputChanged?(103)
        precondition(restored.selectedOutput?.id == 103 && restored.preset.id == secondID)
        precondition(restored.preset.preamp == -2 && restored.presetIsBoundToOutput)
        restored.setPresetBoundToOutput(false)
        precondition(restored.devicePresets["other-headphones"] == nil)
        precondition(restored.devicePresets["headphones"]?.id == firstID)
        restored.router.onSystemOutputChanged?(101)
        precondition(restored.preset.id == firstID && restored.presetIsBoundToOutput)
        print("SAME_NAME_DIFFERENT_UID_TESTS_PASSED")
    }

    @MainActor
    static func testSharedDeviceIdentity() {
        CoreAudioDevices.currentDefaultUID = "headphones"
        let suite = "BridgeEQ.SharedJackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.preset = EQPreset(name: "First analog headphone", preamp: -8, bands: [])
        model.setPresetBoundToOutput(true)
        let firstID = model.preset.id
        // Swapping headphones behind a jack/DAC that reports the same UID
        // supplies no separate device identity to store a second association.
        model.router.onSystemOutputChanged?(1)
        precondition(model.preset.id == firstID && model.presetIsBoundToOutput)
        model.load(EQPreset(name: "Second analog headphone", preamp: -2, bands: []))
        model.setPresetBoundToOutput(true)
        precondition(model.devicePresets.count == 1)
        precondition(model.devicePresets["headphones"]?.name == "Second analog headphone")
        print("SHARED_UID_SINGLE_BINDING_LIMIT_CONFIRMED")
    }

    @MainActor
    static func testGlobalPresets() async throws {
        CoreAudioDevices.currentDefaultUID = "headphones"
        let suite = "BridgeEQ.GlobalPresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.load(EQPreset(name: "Global EQ", preamp: -3, bands: []))
        model.savePreset(named: "Global EQ")
        let global = model.preset
        model.toggle()
        model.router.onSystemOutputChanged?(2)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == global.id)
        precondition(model.router.starts.last?.0 == "speakers")
        precondition(!model.presetIsBoundToOutput)

        // A device preset overrides the global preset on its own output.
        model.load(EQPreset(name: "Headphone only", preamp: -8, bands: []))
        model.selectOutput("headphones")
        model.setPresetBoundToOutput(true)
        let bound = model.preset
        // Explicitly choose the global preset once so it is the fallback.
        model.selectOutput("speakers")
        model.load(global)
        model.router.onSystemOutputChanged?(2)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == global.id)
        model.router.onSystemOutputChanged?(1)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == bound.id)
        model.router.onSystemOutputChanged?(2)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == global.id)
        model.toggle()

        // Remember the global fallback across relaunches without auto-start.
        model.selectOutput("headphones")
        let restored = AppModel(defaults: defaults)
        precondition(restored.preset.id == bound.id && !restored.processingRequested)
        restored.router.onSystemOutputChanged?(2)
        precondition(restored.preset.id == global.id && !restored.router.running)
        restored.router.onSystemOutputChanged?(1)
        restored.setPresetBoundToOutput(false)
        restored.toggle()
        restored.router.onSystemOutputChanged?(2)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(restored.router.running && restored.preset.id == bound.id)
        restored.toggle()
        print("GLOBAL_PRESET_TESTS_PASSED")
    }

    @MainActor
    static func testNoEQOutputs() async throws {
        CoreAudioDevices.currentDefaultUID = "headphones"
        let suite = "BridgeEQ.NoEQTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.load(EQPreset(name: "Hi-fi", preamp: -8, bands: []))
        model.setOutputEQRule(.preset)
        let headphonePreset = model.preset
        model.selectOutput("speakers")
        model.load(EQPreset(name: "Global", preamp: -3, bands: []))
        let global = model.preset
        model.toggle()
        model.setOutputEQRule(.noEQ)
        precondition(model.processingRequested && !model.router.running && !model.router.recovering)
        let count = model.router.starts.count
        model.load(global)
        model.router.onRecoveryNeeded?()
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.starts.count == count)
        precondition(model.outputEQRule == .noEQ && !model.router.running && !model.router.recovering)

        model.router.onSystemOutputChanged?(1)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == headphonePreset.id)
        model.router.onSystemOutputChanged?(2)
        precondition(!model.router.running && !model.router.recovering && model.outputEQRule == .noEQ)
        let restored = AppModel(defaults: defaults)
        precondition(restored.outputEQRule == .noEQ && !restored.processingRequested)
        restored.toggle() // A No EQ output arms routing without processing.
        precondition(restored.processingRequested && restored.router.starts.isEmpty)
        restored.setOutputEQRule(.global)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(restored.router.running && restored.preset.id == global.id)

        // No EQ cancels a pending restart and preserves an existing binding.
        restored.router.onSystemOutputChanged?(1)
        restored.setOutputEQRule(.noEQ)
        let startsBefore = restored.router.starts.count
        try await Task.sleep(for: .milliseconds(1200))
        precondition(restored.router.starts.count == startsBefore && !restored.router.running)
        precondition(restored.devicePresets["headphones"]?.id == headphonePreset.id)
        restored.setOutputEQRule(.preset)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(restored.router.running && restored.preset.id == headphonePreset.id)
        restored.setOutputEQRule(.noEQ)
        restored.toggle() // Explicit Stop disarms routing, including No EQ.
        restored.selectOutput("speakers")
        precondition(!restored.processingRequested && !restored.router.running)
        print("NO_EQ_OUTPUT_TESTS_PASSED")
    }

    @MainActor
    static func testOutputSynchronizationAndExplicitGlobal() async throws {
        CoreAudioDevices.currentDefaultUID = "headphones"
        let suite = "BridgeEQ.OutputSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.load(EQPreset(name: "Global A", preamp: -3, bands: []))
        model.savePreset(named: "Global A")
        let first = model.preset
        model.load(EQPreset(name: "Global B", preamp: -5, bands: []))
        model.savePreset(named: "Global B")
        let second = model.preset
        model.setGlobalPreset(first)
        model.toggle()
        precondition(model.selectOutput("speakers"))
        precondition(CoreAudioDevices.defaultOutputDeviceID() == 2)
        model.setOutputEQRule(.noEQ)
        precondition(!model.router.running && !model.router.recovering)
        precondition(CoreAudioDevices.defaultOutputDeviceID() == model.selectedOutput?.id)
        model.load(second) // Browsing a preset in No EQ must not change fallback.
        precondition(model.globalPreset?.id == first.id)
        model.setOutputEQRule(.global)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == first.id)
        model.setGlobalPreset(second)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == second.id)
        model.setOutputEQRule(.preset)
        precondition(model.selectOutput("headphones"))
        precondition(CoreAudioDevices.defaultOutputDeviceID() == 1)
        model.setGlobalPreset(first)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.router.running && model.preset.id == first.id)

        // A rejected system output switch must not leave a mismatched picker
        // or start processing on a destination macOS did not select.
        CoreAudioDevices.rejectOutputChange = true
        precondition(!model.selectOutput("speakers"))
        CoreAudioDevices.rejectOutputChange = false
        precondition(model.outputUID == "headphones" && !model.router.running)
        precondition(model.errorMessage != nil)
        let restored = AppModel(defaults: defaults)
        precondition(restored.globalPreset?.id == first.id)
        restored.setGlobalPreset(nil)
        restored.toggle()
        precondition(!restored.router.running && restored.processingRequested)
        precondition(AppModel(defaults: defaults).globalPreset == nil)
        print("OUTPUT_SYNC_AND_EXPLICIT_GLOBAL_TESTS_PASSED")
    }

    @MainActor
    static func testDelayedSystemOutputChanges() async throws {
        CoreAudioDevices.currentDefaultUID = "headphones"
        let suite = "BridgeEQ.DelayedControlCenterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.load(EQPreset(name: "Global", preamp: -3, bands: []))
        model.selectOutput("speakers")
        model.setOutputEQRule(.noEQ)
        model.selectOutput("headphones")
        model.toggle()

        // Control Center changes the default before delivering its callback.
        CoreAudioDevices.currentDefaultUID = "speakers"
        let writes = CoreAudioDevices.outputWrites.count
        model.selectOutput("headphones") // Unchanged stale picker action.
        precondition(CoreAudioDevices.outputWrites.count == writes)
        precondition(CoreAudioDevices.defaultOutputDeviceID() == 2)
        model.toggle() // Stop.
        model.toggle() // Start must follow speakers without changing macOS.
        precondition(model.outputUID == "speakers" && !model.router.running)
        precondition(CoreAudioDevices.outputWrites.count == writes)
        model.toggle() // Disarm.

        model.selectOutput("headphones")
        model.toggle()
        model.router.onRecoveryNeeded?() // A restart on the old route is pending.
        CoreAudioDevices.currentDefaultUID = "speakers"
        let restartCount = model.router.starts.count
        let writesBeforeRecovery = CoreAudioDevices.outputWrites.count
        try await Task.sleep(for: .milliseconds(1500))
        precondition(model.outputUID == "speakers" && model.outputEQRule == .noEQ)
        precondition(!model.router.running && !model.router.recovering)
        precondition(model.router.starts.count == restartCount)
        precondition(CoreAudioDevices.outputWrites.count == writesBeforeRecovery)

        // Rapid external changes also remain authoritative during recovery.
        model.router.onSystemOutputChanged?(1)
        CoreAudioDevices.currentDefaultUID = "other-headphones"
        try await Task.sleep(for: .milliseconds(2400))
        precondition(model.outputUID == "other-headphones" && model.router.running)
        precondition(model.router.starts.last?.0 == "other-headphones")
        precondition(CoreAudioDevices.defaultOutputDeviceID() == 3)
        model.toggle()
        print("DELAYED_SYSTEM_OUTPUT_TESTS_PASSED")
    }
}
