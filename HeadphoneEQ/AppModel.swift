import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var outputUID = "" { didSet {
        saveState()
        if outputUID != oldValue, router.running || router.recovering { scheduleRecovery() }
    } }
    @Published var preset: EQPreset = .flat { didSet { router.update(preset); saveState() } }
    @Published var presets: [EQPreset] = []
    @Published var errorMessage: String?
    let router = AudioRouter()
    private var retryTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private var restoringState = true

    var outputs: [AudioDevice] { devices.filter { $0.outputChannels > 0 && CoreAudioDevices.isPhysicalOutput($0.id) } }
    var selectedOutput: AudioDevice? { devices.first { $0.uid == outputUID } }

    init() {
        loadState()
        restoringState = false
        refreshDevices()
        router.onRecoveryNeeded = { [weak self] in self?.scheduleRecovery() }
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
        if router.running || router.recovering { retryTask?.cancel(); router.stop(); return }
        guard let output = selectedOutput else { errorMessage = "Choose an available headphones, speakers, or DAC output."; return }
        do { try router.start(output: output, preset: preset) }
        catch { errorMessage = error.localizedDescription }
    }

    func addBand() { preset.bands.append(EQBand(frequency: 1000)) }
    func deleteBand(_ id: UUID) { preset.bands.removeAll { $0.id == id } }
    func savePreset(named name: String) {
        var copy = preset; copy.id = UUID(); copy.name = name.isEmpty ? "Untitled" : name
        presets.removeAll { $0.name.caseInsensitiveCompare(copy.name) == .orderedSame }
        presets.append(copy); preset = copy; persistPresets()
    }
    func load(_ item: EQPreset) { preset = item }
    func deletePreset(_ item: EQPreset) { presets.removeAll { $0.id == item.id }; persistPresets() }

    func importText(_ text: String, name: String = "Imported") throws {
        preset = try APOParser.parse(text, name: name)
    }
    func exportText() -> String { APOParser.serialize(preset) }

    private func scheduleRecovery() {
        retryTask?.cancel()
        router.beginRecovery()
        retryTask = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshDevices()
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
            self?.errorMessage = "The audio devices did not reconnect. Check the connections, then press Start."
        }
    }

    private func loadState() {
        outputUID = defaults.string(forKey: "outputUID") ?? ""
        if let data = defaults.data(forKey: "currentPreset"), let value = try? JSONDecoder().decode(EQPreset.self, from: data) { preset = value }
        if let data = defaults.data(forKey: "presets"), let value = try? JSONDecoder().decode([EQPreset].self, from: data) { presets = value }
    }
    private func saveState() {
        // Loading the output selection must not overwrite the preset before
        // loadState has read it from defaults.
        guard !restoringState else { return }
        defaults.set(outputUID, forKey: "outputUID")
        defaults.set(try? JSONEncoder().encode(preset), forKey: "currentPreset")
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
