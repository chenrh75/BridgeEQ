import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var inputUID = "" { didSet { saveState() } }
    @Published var outputUID = "" { didSet { saveState() } }
    @Published var preset: EQPreset = .flat { didSet { router.update(preset); saveState() } }
    @Published var presets: [EQPreset] = []
    @Published var errorMessage: String?
    let router = AudioRouter()
    private var retryTask: Task<Void, Never>?
    private var routerSubscription: AnyCancellable?
    private let defaults = UserDefaults.standard

    var inputs: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }
    var outputs: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }
    var selectedInput: AudioDevice? { devices.first { $0.uid == inputUID } }
    var selectedOutput: AudioDevice? { devices.first { $0.uid == outputUID } }

    init() {
        routerSubscription = router.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        loadState(); refreshDevices()
        router.onRecoveryNeeded = { [weak self] in self?.scheduleRecovery() }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test-route") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { Foundation.exit(2) }
                self.toggle()
                try? await Task.sleep(for: .seconds(2))
                if self.router.running {
                    print("ROUTE_SMOKE_TEST_PASSED: \(self.router.status)")
                    self.router.stop()
                    Foundation.exit(0)
                } else {
                    print("ROUTE_SMOKE_TEST_FAILED: \(self.errorMessage ?? self.router.status)")
                    Foundation.exit(2)
                }
            }
        }
    }

    func refreshDevices() {
        devices = CoreAudioDevices.all()
        if !inputs.contains(where: { $0.uid == inputUID }) { inputUID = inputs.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole") })?.uid ?? inputs.first?.uid ?? "" }
        if !outputs.contains(where: { $0.uid == outputUID }) { outputUID = outputs.first(where: { !$0.name.localizedCaseInsensitiveContains("BlackHole") })?.uid ?? outputs.first?.uid ?? "" }
    }

    func toggle() {
        if router.running { retryTask?.cancel(); router.stop(); return }
        guard let input = selectedInput, let output = selectedOutput else { errorMessage = "Choose an available input and output device."; return }
        guard input.uid != output.uid else {
            errorMessage = "Input and output must be different devices. Choose BlackHole 2ch as Input and your headphones or DAC as Output."
            return
        }
        guard !output.name.localizedCaseInsensitiveContains("BlackHole") else {
            errorMessage = "BlackHole should be the Input, not the Output. Choose your headphones, built-in output, or DAC as Output."
            return
        }
        do { try router.start(input: input, output: output, preset: preset) }
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
        retryTask = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshDevices()
                guard let i = self.selectedInput, let o = self.selectedOutput else { continue }
                if (try? self.router.start(input: i, output: o, preset: self.preset)) != nil { return }
            }
            self?.errorMessage = "The audio devices did not reconnect. Check the connections, then press Start."
        }
    }

    private func loadState() {
        inputUID = defaults.string(forKey: "inputUID") ?? ""
        outputUID = defaults.string(forKey: "outputUID") ?? ""
        if let data = defaults.data(forKey: "currentPreset"), let value = try? JSONDecoder().decode(EQPreset.self, from: data) { preset = value }
        if let data = defaults.data(forKey: "presets"), let value = try? JSONDecoder().decode([EQPreset].self, from: data) { presets = value }
    }
    private func saveState() {
        defaults.set(inputUID, forKey: "inputUID"); defaults.set(outputUID, forKey: "outputUID")
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
