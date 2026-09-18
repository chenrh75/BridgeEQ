import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var presetName = ""
    @State private var importing = false
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    devices
                    controls
                    bands
                    presets
                }.padding(20)
            }
        }
        .alert("BridgeEQ", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; try model.importText(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent) } catch { model.errorMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: TextDocument(text: model.exportText()), contentType: .plainText, defaultFilename: "\(model.preset.name).txt") { if case let .failure(error) = $0 { model.errorMessage = error.localizedDescription } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) { Text("BridgeEQ").font(.title.bold()); Text(model.router.status).foregroundStyle(.secondary) }
            Spacer()
            StereoMeter(label: "IN", left: model.router.meter.inputLeft, right: model.router.meter.inputRight,
                        leftHold: model.router.meter.inputLeftHold, rightHold: model.router.meter.inputRightHold,
                        leftClipped: model.router.meter.inputLeftClips, rightClipped: model.router.meter.inputRightClips)
            StereoMeter(label: "OUT", left: model.router.meter.outputLeft, right: model.router.meter.outputRight,
                        leftHold: model.router.meter.outputLeftHold, rightHold: model.router.meter.outputRightHold,
                        leftClipped: model.router.meter.outputLeftClips, rightClipped: model.router.meter.outputRightClips)
            Button(model.router.running ? "Stop" : "Start") { model.toggle() }.buttonStyle(.borderedProminent).tint(model.router.running ? .red : .accentColor).controlSize(.large)
        }
    }

    private var devices: some View {
        GroupBox("Audio route") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow { Text("Input"); Picker("Input", selection: $model.inputUID) { ForEach(model.inputs) { Text($0.label).tag($0.uid) } }.labelsHidden() }
                GridRow { Text("Output"); Picker("Output", selection: $model.outputUID) { ForEach(model.outputs) { Text($0.label).tag($0.uid) } }.labelsHidden() }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            HStack { Spacer(); Button("Refresh devices") { model.refreshDevices() } }
        }
    }

    private var controls: some View {
        GroupBox("Signal") {
            HStack(spacing: 20) {
                Toggle("Bypass all EQ", isOn: $model.preset.globalBypass)
                LabeledNumber(label: "Preamp", value: $model.preset.preamp, range: -24...12, suffix: "dB")
                LabeledNumber(label: "Output", value: $model.preset.outputGain, range: -24...12, suffix: "dB")
            }.padding(8)
        }
    }

    private var bands: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack { Text("EQ bands").font(.headline); Spacer(); Button("Add band", systemImage: "plus") { model.addBand() } }
                ForEach($model.preset.bands) { $band in
                    HStack {
                        Toggle("", isOn: $band.enabled).labelsHidden()
                        Picker("Type", selection: $band.type) { ForEach(EQFilterType.allCases) { Text($0.title).tag($0) } }.frame(width: 130)
                        LabeledNumber(label: "Frequency", value: $band.frequency, range: 10...24000, suffix: "Hz")
                        LabeledNumber(label: "Gain", value: $band.gain, range: -24...24, suffix: "dB")
                        LabeledNumber(label: "Q", value: $band.q, range: 0.1...20, suffix: "")
                        Button(role: .destructive) { model.deleteBand(band.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }.padding(.vertical, 3)
                }
            }.padding(8)
        }
    }

    private var presets: some View {
        GroupBox("Presets") {
            HStack {
                TextField("Preset name", text: $presetName).frame(width: 180)
                Button("Save") { model.savePreset(named: presetName); presetName = "" }
                Menu("Load") { ForEach(model.presets) { p in Button(p.name) { model.load(p) } } }
                Spacer()
                Button("Import APO / AutoEQ…") { importing = true }
                Button("Export…") { exporting = true }
            }.padding(8)
        }
    }
}

private struct LabeledNumber: View {
    let label: String; @Binding var value: Double; let range: ClosedRange<Double>; let suffix: String
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = true
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter
    }()

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: $value, formatter: Self.decimalFormatter)
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
            Text(suffix).foregroundStyle(.secondary)
        }
    }
}

private struct StereoMeter: View {
    let label: String
    let left: Float, right: Float, leftHold: Float, rightHold: Float
    let leftClipped: Bool, rightClipped: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.monospaced())
            MeterChannel(channel: "L", value: left, hold: leftHold, clipped: leftClipped)
            MeterChannel(channel: "R", value: right, hold: rightHold, clipped: rightClipped)
        }
    }
}

private struct MeterChannel: View {
    let channel: String; let value: Float; let hold: Float; let clipped: Bool
    private func position(_ amplitude: Float) -> Double {
        let db = 20 * log10(max(Double(amplitude), 0.001))
        return min(max((db + 60) / 60, 0), 1)
    }
    var body: some View {
        HStack(spacing: 4) {
            Text(channel).font(.caption2.monospaced()).frame(width: 9)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.18))
                    Capsule().fill(clipped ? .red : .green).frame(width: geometry.size.width * position(value))
                    Rectangle().fill(.white).frame(width: 2, height: 8).offset(x: max(0, geometry.size.width * position(hold) - 1))
                }
            }.frame(width: 100, height: 8)
            Text(clipped ? "CLIP" : String(format: "%3.0f", 20 * log10(max(Double(value), 0.001))))
                .font(.caption2.monospaced()).foregroundStyle(clipped ? .red : .secondary).frame(width: 30, alignment: .trailing)
        }
        .transaction { $0.animation = nil }
    }
}

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: Data(text.utf8)) }
}
