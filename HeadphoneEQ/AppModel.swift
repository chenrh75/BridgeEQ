import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var outputUID = "" { didSet {
        if !restoringState, outputUID != oldValue {
            outputChanged()
        }
        saveState()
    } }
    @Published var preset: EQPreset = .flat { didSet {
        guard !restoringState else { return }
        if devicePresets[outputUID]?.id == preset.id { devicePresets[outputUID] = preset }
        if globalPreset?.id == preset.id, presetIsGlobal { globalPreset = preset }
        router.update(preset)
        saveState()
    } }
    @Published var presets: [EQPreset] = []
    @Published private(set) var devicePresets: [String: EQPreset] = [:]
    @Published private(set) var outputRules: [String: OutputEQRule] = [:]
    @Published private(set) var processingRequested = false
    @Published var errorMessage: String?
    let router = AudioRouter()
    private var retryTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var restoringState = true
    @Published private(set) var globalPreset: EQPreset?
    var globalPresets: [EQPreset] {
        var choices = presets.filter { isGlobal($0) }
        if let globalPreset, !choices.contains(where: { $0.id == globalPreset.id }) { choices.append(globalPreset) }
        return choices
    }

    var outputs: [AudioDevice] { devices.filter { $0.outputChannels > 0 && CoreAudioDevices.isPhysicalOutput($0.id) } }
    var selectedOutput: AudioDevice? { devices.first { $0.uid == outputUID } }
    var outputEQRule: OutputEQRule {
        let rule = outputRules[outputUID] ?? (devicePresets[outputUID] == nil ? .global : .preset)
        return rule == .preset && devicePresets[outputUID] == nil ? .global : rule
    }
    var presetIsBoundToOutput: Bool { outputEQRule == .preset && devicePresets[outputUID]?.id == preset.id }
    private var presetIsGlobal: Bool { isGlobal(preset) }
    private func isGlobal(_ item: EQPreset) -> Bool {
        !devicePresets.values.contains { $0.id == item.id }
    }
    private var presetIsBoundElsewhere: Bool {
        !presetIsBoundToOutput && devicePresets.values.contains { $0.id == preset.id }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadState()
        devices = CoreAudioDevices.all()
        if let systemOutput = outputs.first(where: { $0.id == CoreAudioDevices.defaultOutputDeviceID() }) {
            outputUID = systemOutput.uid
        }
        restoringState = false
        refreshDevices()
        outputChanged()
        router.onRecoveryNeeded = { [weak self] in self?.scheduleRecovery() }
        router.onSystemOutputChanged = { [weak self] id in
            guard let self else { return }
            // Refresh before resolving the ID: a newly connected device may
            // become the system default before it appears in our picker.
            self.devices = CoreAudioDevices.all()
            if let output = self.outputs.first(where: { $0.id == id }) {
                if self.outputUID == output.uid { self.outputChanged() }
                else { self.outputUID = output.uid }
            } else {
                self.stopProcessing()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test-route") {
            let routeTestSeconds = ProcessInfo.processInfo.environment["BRIDGEEQ_ROUTE_TEST_SECONDS"]
                .flatMap(Double.init) ?? 2
            let requireAudio = ProcessInfo.processInfo.environment["BRIDGEEQ_SMOKE_REQUIRE_AUDIO"] == "1"
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { Foundation.exit(2) }
                let originalDefault = CoreAudioDevices.defaultOutputDeviceID()
                if requireAudio, let output = self.selectedOutput {
                    // Test a known attenuation without changing saved presets.
                    var testPreset = EQPreset.flat
                    testPreset.preamp = -12
                    do { try self.router.start(output: output, preset: testPreset) }
                    catch { self.errorMessage = error.localizedDescription }
                } else { self.toggle() }
                let deadline = Date().addingTimeInterval(routeTestSeconds)
                var inputPeak: Float = 0, outputPeak: Float = 0
                while Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                    inputPeak = max(inputPeak, self.router.meters.state.inputLeftHold)
                    outputPeak = max(outputPeak, self.router.meters.state.outputLeftHold)
                }
                let gainDB = inputPeak > 0 && outputPeak > 0 ? 20 * log10(outputPeak / inputPeak) : Float.infinity
                let status = self.router.status
                let passed = self.router.running && CoreAudioDevices.defaultOutputDeviceID() == originalDefault
                    && (!requireAudio || (inputPeak > 0.00001 && outputPeak > 0.00001 && abs(gainDB + 12) < 1))
                self.router.stop()
                if requireAudio { print("ROUTE_SIGNAL: inputPeak=\(inputPeak), outputPeak=\(outputPeak), gainDB=\(gainDB)") }
                print("\(passed ? "ROUTE_SMOKE_TEST_PASSED" : "ROUTE_SMOKE_TEST_FAILED"): \(self.errorMessage ?? status)")
                Foundation.exit(passed ? 0 : 2)
            }
        }
    }

    func refreshDevices() {
        devices = CoreAudioDevices.all()
        // Keep a disconnected selection while recovering; do not unexpectedly
        // send headphone audio to speakers when a DAC is unplugged.
        if !router.recovering, !outputs.contains(where: { $0.uid == outputUID }) {
            outputUID = outputs.first(where: { $0.id == CoreAudioDevices.defaultOutputDeviceID() })?.uid ?? outputs.first?.uid ?? ""
        }
    }

    func toggle() {
        if processingRequested || router.running || router.recovering { stopProcessing(); return }
        // Start follows macOS. It must not undo a Control Center selection
        // just because its notification has not reached the main actor yet.
        guard followSystemOutput() else { return }
        guard let output = selectedOutput else { errorMessage = "Choose an available headphones, speakers, or DAC output."; return }
        if outputEQRule == .noEQ {
            // Arm automatic routing without creating a capture/playback path.
            processingRequested = true
            return
        }
        if outputEQRule == .global, globalPreset == nil {
            processingRequested = true
            return
        }
        guard !presetIsBoundElsewhere else {
            errorMessage = "This preset is bound to another output. Choose a different preset or bind it to \(output.name) before starting."
            return
        }
        processingRequested = true
        do { try router.start(output: output, preset: preset) }
        catch { processingRequested = false; errorMessage = error.localizedDescription }
    }

    @discardableResult
    func selectOutput(_ uid: String) -> Bool {
        guard let output = outputs.first(where: { $0.uid == uid }) else {
            errorMessage = "The selected output is no longer available."
            return false
        }
        // An unchanged picker action can arrive during a system-originated
        // refresh. Never use it to reassert a stale app selection.
        guard outputUID != uid else { return true }
        let resume = processingRequested || router.running || router.recovering
        stopProcessing()
        do {
            try CoreAudioDevices.setDefaultOutputDeviceID(output.id)
            router.acknowledgeSystemOutputChange()
            processingRequested = resume
            if outputUID == uid { outputChanged() }
            else { outputUID = uid }
            return true
        } catch {
            if let actual = outputs.first(where: { $0.id == CoreAudioDevices.defaultOutputDeviceID() }) {
                outputUID = actual.uid
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func followSystemOutput() -> Bool {
        devices = CoreAudioDevices.all()
        guard let actual = outputs.first(where: { $0.id == CoreAudioDevices.defaultOutputDeviceID() }) else {
            stopProcessing()
            return false
        }
        if outputUID != actual.uid { outputUID = actual.uid }
        return true
    }

    func setGlobalPreset(_ item: EQPreset?) {
        guard item.map({ isGlobal($0) }) ?? true else { return }
        globalPreset = item
        if outputEQRule == .global { outputChanged() }
        saveState()
    }

    private func stopProcessing() {
        retryTask?.cancel()
        retryTask = nil
        processingRequested = false
        router.stop()
    }

    private func outputChanged() {
        let resume = processingRequested || router.running || router.recovering
        stopProcessing()
        if outputEQRule == .noEQ {
            processingRequested = resume
            return
        }
        let destinationPreset = (outputEQRule == .preset ? devicePresets[outputUID] : nil)
            ?? globalPreset.flatMap { isGlobal($0) ? $0 : nil }
        guard let destinationPreset else {
            // A device-specific preset cannot spill onto another device.
            // Wait only when there is no global preset to use instead.
            processingRequested = resume
            return
        }
        if preset != destinationPreset { preset = destinationPreset }
        processingRequested = resume
        if resume { scheduleRecovery() }
    }

    func setPresetBoundToOutput(_ enabled: Bool) {
        guard selectedOutput != nil else { return }
        if enabled {
            outputRules[outputUID] = .preset
            devicePresets[outputUID] = preset
        } else if devicePresets[outputUID]?.id == preset.id {
            devicePresets.removeValue(forKey: outputUID)
            outputRules.removeValue(forKey: outputUID)
        }
        if !enabled, presetIsGlobal { globalPreset = preset }
        else if globalPreset?.id == preset.id { globalPreset = nil }
        saveState()
        if processingRequested, presetIsBoundElsewhere || (!router.running && !router.recovering) { outputChanged() }
    }

    func setOutputEQRule(_ rule: OutputEQRule) {
        guard selectedOutput != nil else { return }
        outputRules[outputUID] = rule
        if rule == .preset {
            let bound = devicePresets[outputUID] ?? preset
            devicePresets[outputUID] = bound
            if globalPreset?.id == bound.id { globalPreset = nil }
        }
        // Keep an existing binding when choosing No EQ or Use global so it
        // can be restored later. The output rule always takes precedence.
        outputChanged()
        saveState()
    }

    func addBand() { preset.bands.append(EQBand(frequency: 1000)) }
    func deleteBand(_ id: UUID) { preset.bands.removeAll { $0.id == id } }
    func savePreset(named name: String) {
        let previousID = preset.id
        var copy = preset
        copy.name = name.isEmpty ? "Untitled" : name
        copy.id = presets.first { $0.name.caseInsensitiveCompare(copy.name) == .orderedSame }?.id ?? UUID()
        presets.removeAll { $0.name.caseInsensitiveCompare(copy.name) == .orderedSame }
        devicePresets = devicePresets.mapValues { $0.id == copy.id ? copy : $0 }
        // Save As moves only this device to the new preset; other devices
        // retain their existing preset associations.
        if devicePresets[outputUID]?.id == previousID { devicePresets[outputUID] = copy }
        if outputEQRule == .global, isGlobal(copy) { globalPreset = copy }
        presets.append(copy); preset = copy; persistPresets()
    }
    func load(_ item: EQPreset) {
        if outputEQRule == .preset {
            devicePresets[outputUID] = item
            if globalPreset?.id == item.id { globalPreset = nil }
        }
        if outputEQRule != .noEQ, devicePresets[outputUID]?.id != item.id, devicePresets.values.contains(where: { $0.id == item.id }) {
            stopProcessing()
        }
        if outputEQRule == .global, isGlobal(item) { globalPreset = item }
        preset = item
        // Selecting a global preset while waiting for a device preset should
        // resume the session immediately. Explicit Stop still stays stopped.
        if processingRequested, !router.running, !router.recovering { outputChanged() }
    }
    func deletePreset(_ item: EQPreset) {
        presets.removeAll { $0.id == item.id }
        devicePresets = devicePresets.filter { $0.value.id != item.id }
        if globalPreset?.id == item.id { globalPreset = nil }
        persistPresets(); saveState()
        if outputEQRule == .global { outputChanged() }
    }

    func importText(_ text: String, name: String = "Imported") throws {
        load(try APOParser.parse(text, name: name))
    }
    func exportText() -> String { APOParser.serialize(preset) }

    private func scheduleRecovery() {
        guard outputEQRule != .noEQ else { outputChanged(); return }
        retryTask?.cancel()
        router.beginRecovery()
        retryTask = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                // A Control Center change can precede its Core Audio callback.
                // Adopt it before restarting, never restart the previous route.
                self.followSystemOutput()
                guard !Task.isCancelled else { return }
                self.refreshDevices()
                guard self.outputEQRule != .noEQ else { self.outputChanged(); return }
                guard let o = self.selectedOutput else { continue }
                do {
                    try self.router.start(output: o, preset: self.preset)
                    return
                } catch {
                    self.router.beginRecovery()
                }
            }
            guard !Task.isCancelled else { return }
            self?.router.stop()
            self?.processingRequested = false
            self?.errorMessage = "The audio devices did not reconnect. Check the connections, then press Start."
        }
    }

    private func loadState() {
        outputUID = defaults.string(forKey: "outputUID") ?? ""
        if let data = defaults.data(forKey: "currentPreset"), let value = try? JSONDecoder().decode(EQPreset.self, from: data) { preset = value }
        if let data = defaults.data(forKey: "presets"), let value = try? JSONDecoder().decode([EQPreset].self, from: data) { presets = value }
        if let data = defaults.data(forKey: "devicePresets"), let value = try? JSONDecoder().decode([String: EQPreset].self, from: data) { devicePresets = value }
        if let data = defaults.data(forKey: "outputRules"), let value = try? JSONDecoder().decode([String: OutputEQRule].self, from: data) { outputRules = value }
        if let data = defaults.data(forKey: "globalPreset"), let value = try? JSONDecoder().decode(EQPreset.self, from: data), isGlobal(value) { globalPreset = value }
    }
    private func saveState() {
        // Loading the output selection must not overwrite the preset before
        // loadState has read it from defaults.
        guard !restoringState else { return }
        defaults.set(outputUID, forKey: "outputUID")
        defaults.set(try? JSONEncoder().encode(preset), forKey: "currentPreset")
        defaults.set(try? JSONEncoder().encode(devicePresets), forKey: "devicePresets")
        defaults.set(try? JSONEncoder().encode(outputRules), forKey: "outputRules")
        defaults.set(globalPreset.flatMap { try? JSONEncoder().encode($0) }, forKey: "globalPreset")
    }
    private func persistPresets() { defaults.set(try? JSONEncoder().encode(presets), forKey: "presets") }
}

enum APOParser {
    enum ParseError: LocalizedError { case noFilters; var errorDescription: String? { "No supported Equalizer APO filters were found." } }
    static func parse(_ text: String, name: String) throws -> EQPreset {
        var result = EQPreset(name: name, bands: [])
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("preamp:") { result.preamp = number(after: "Preamp:", in: line) ?? 0; continue }
            guard line.lowercased().hasPrefix("filter"), let fc = number(after: "Fc", in: line) else { continue }
            let upper = line.uppercased()
            let type: EQFilterType = upper.contains(" LS ") ? .lowShelf : upper.contains(" HS ") ? .highShelf : upper.contains(" LP ") ? .lowPass : upper.contains(" HP ") ? .highPass : .parametric
            result.bands.append(EQBand(enabled: !upper.contains(" OFF "), type: type, frequency: fc, gain: number(after: "Gain", in: line) ?? 0, q: number(after: "Q", in: line) ?? 1))
        }
        guard !result.bands.isEmpty else { throw ParseError.noFilters }
        return result
    }
    static func serialize(_ p: EQPreset) -> String {
        var lines = ["Preamp: \(fmt(p.preamp)) dB"]
        for (i, b) in p.bands.enumerated() {
            let code = [.parametric:"PK", .lowShelf:"LS", .highShelf:"HS", .lowPass:"LP", .highPass:"HP"][b.type]!
            lines.append("Filter \(i + 1): \(b.enabled ? "ON" : "OFF") \(code) Fc \(fmt(b.frequency)) Hz Gain \(fmt(b.gain)) dB Q \(fmt(b.q))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
    private static func number(after marker: String, in line: String) -> Double? {
        guard let range = line.range(of: marker, options: .caseInsensitive) else { return nil }
        return line[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" }).first.flatMap { Double($0) }
    }
    private static func fmt(_ value: Double) -> String { String(format: "%.3f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
}
