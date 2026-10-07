import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CoreText

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var presetName = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var presetToDelete: EQPreset?

    var body: some View {
        VStack(spacing: 0) {
            RouterHeader(router: model.router, toggle: model.toggle)
                .frame(maxWidth: 1050)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    devices
                    controls
                    bands
                    presets
                }
                .frame(maxWidth: 1050)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("BridgeEQ", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(
            "Delete preset “\(presetToDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { presetToDelete != nil },
                set: { if !$0 { presetToDelete = nil } }
            )
        ) {
            if let presetToDelete {
                Button("Delete", role: .destructive) {
                    model.deletePreset(presetToDelete)
                    self.presetToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { presetToDelete = nil }
        } message: {
            Text("This removes the saved preset. The current EQ settings will remain unchanged.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; try model.importText(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent) } catch { model.errorMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: TextDocument(text: model.exportText()), contentType: .plainText, defaultFilename: "\(model.preset.name).txt") { if case let .failure(error) = $0 { model.errorMessage = error.localizedDescription } }
    }

    private var devices: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Input"); Picker("Input", selection: $model.inputUID) { ForEach(model.inputs) { Text($0.label).tag($0.uid) } }.labelsHidden() }
                GridRow { Text("Output"); Picker("Output", selection: $model.outputUID) { ForEach(model.outputs) { Text($0.label).tag($0.uid) } }.labelsHidden() }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 5)
        } label: {
            HStack {
                Text("Audio route")
                Spacer()
                Button("Refresh devices", systemImage: "arrow.clockwise") { model.refreshDevices() }.controlSize(.small)
            }.frame(maxWidth: .infinity)
        }
    }

    private var controls: some View {
        GroupBox("Signal") {
            HStack(spacing: 16) {
                Toggle("Bypass all EQ", isOn: $model.preset.globalBypass)
                LabeledNumber(label: "Preamp", value: $model.preset.preamp, range: -24...12, suffix: "dB")
                LabeledNumber(label: "Output", value: $model.preset.outputGain, range: -24...12, suffix: "dB")
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity)
    }

    private var bands: some View {
        GroupBox {
            VStack(spacing: 5) {
                ForEach($model.preset.bands) { $band in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $band.enabled).labelsHidden()
                        Picker("Type", selection: $band.type) { ForEach(EQFilterType.allCases) { Text($0.title).tag($0) } }.frame(width: 160)
                        LabeledNumber(label: "Frequency", value: $band.frequency, range: 10...24000, suffix: "Hz")
                        LabeledNumber(label: "Gain", value: $band.gain, range: -24...24, suffix: "dB")
                        LabeledNumber(label: "Q", value: $band.q, range: 0.1...20, suffix: "")
                        Button(role: .destructive) { model.deleteBand(band.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }.padding(.vertical, 1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 5)
        } label: {
            HStack {
                Text("EQ bands")
                Spacer()
                Button("EQ curve", systemImage: "chart.xyaxis.line") { openWindow(id: "eq-curve") }.controlSize(.small)
                Button("Add band", systemImage: "plus") { model.addBand() }.controlSize(.small)
            }.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var presets: some View {
        GroupBox("Presets") {
            HStack {
                TextField("Preset name", text: $presetName).frame(width: 180)
                Button("Save") { model.savePreset(named: presetName); presetName = "" }
                Menu("Load") { ForEach(model.presets) { p in Button(p.name) { model.load(p) } } }
                Menu("Delete") {
                    ForEach(model.presets) { preset in
                        Button(preset.name, role: .destructive) { presetToDelete = preset }
                    }
                }
                .disabled(model.presets.isEmpty)
                Spacer()
                Button("Import APO / AutoEQ…") { importing = true }
                Button("Export…") { exporting = true }
            }.padding(.horizontal, 6).padding(.vertical, 5)
        }
    }
}

private struct RouterHeader: View {
    @ObservedObject var router: AudioRouter
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("BridgeEQ").font(.title2.bold())
                Text(router.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }.fixedSize(horizontal: true, vertical: false)
            Spacer()
            MeterDisplay(meters: router.meters)
                .frame(width: 282, height: 38)
                .fixedSize()
            Button(router.running ? "Stop" : "Start", action: toggle)
                .buttonStyle(.borderedProminent).tint(router.running ? .red : .accentColor)
        }
    }
}

private struct MeterDisplay: NSViewRepresentable {
    let meters: MeterModel

    func makeNSView(context: Context) -> MeterView {
        let view = MeterView()
        view.model = meters
        meters.onUpdate = { [weak view] state in view?.state = state }
        view.state = meters.state
        return view
    }

    func updateNSView(_ view: MeterView, context: Context) {
        meters.onUpdate = { [weak view] state in view?.state = state }
        view.state = meters.state
    }

    static func dismantleNSView(_ view: MeterView, coordinator: ()) {
        view.model?.onUpdate = nil
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

private final class MeterView: NSView {
    weak var model: MeterModel?
    var state = MeterState() { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 282, height: 38) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawStereo(label: "IN", x: 0, values: (state.inputLeft, state.inputRight),
                   holds: (state.inputLeftHold, state.inputRightHold), clips: (state.inputLeftClips, state.inputRightClips))
        drawStereo(label: "OUT", x: 143, values: (state.outputLeft, state.outputRight),
                   holds: (state.outputLeftHold, state.outputRightHold), clips: (state.outputLeftClips, state.outputRightClips))
    }

    private func drawStereo(label: String, x: CGFloat, values: (Float, Float), holds: (Float, Float), clips: (Bool, Bool)) {
        drawText(label, at: CGPoint(x: x, y: 25), color: .secondaryLabelColor, size: 10)
        drawChannel("L", value: values.0, hold: holds.0, clipped: clips.0, x: x, y: 14)
        drawChannel("R", value: values.1, hold: holds.1, clipped: clips.1, x: x, y: 2)
    }

    private func drawChannel(_ channel: String, value: Float, hold: Float, clipped: Bool, x: CGFloat, y: CGFloat) {
        drawText(channel, at: CGPoint(x: x, y: y), color: .secondaryLabelColor, size: 9)
        let bar = NSRect(x: x + 13, y: y, width: 92, height: 7)
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
        let width = bar.width * position(value)
        if width > 0 {
            (clipped ? NSColor.systemRed : NSColor.systemGreen).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: width, height: bar.height), xRadius: 4, yRadius: 4).fill()
        }
        NSColor.white.setFill()
        NSRect(x: bar.minX + min(bar.width - 2, max(0, bar.width * position(hold) - 1)), y: y, width: 2, height: 7).fill()
        let text = clipped ? "CLIP" : String(format: "%3.0f", 20 * log10(max(Double(value), 0.001)))
        drawText(text, at: CGPoint(x: x + 109, y: y), color: clipped ? .systemRed : .secondaryLabelColor, size: 9)
    }

    private func drawText(_ text: String, at point: CGPoint, color: NSColor, size: CGFloat) {
        // Draw cached glyph outlines instead of creating attributed strings.
        // This keeps the macOS 27 CoreText attribute-dictionary crash out of
        // the meter's continuously-redrawn path while retaining crisp text.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let font = size >= 10 ? Self.labelMeterFont : Self.valueMeterFont
        var x = point.x

        context.saveGState()
        context.beginPath()
        for character in text.uppercased() {
            guard let glyph = font.glyphs[character] else {
                x += font.fallbackAdvance
                continue
            }
            if let path = glyph.path {
                context.saveGState()
                context.translateBy(x: x, y: point.y)
                context.addPath(path)
                context.restoreGState()
            }
            x += glyph.advance
        }
        context.setFillColor((color.usingColorSpace(.deviceRGB) ?? color).cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private struct MeterGlyph {
        let path: CGPath?
        let advance: CGFloat
    }

    private final class MeterFont {
        let glyphs: [Character: MeterGlyph]
        let fallbackAdvance: CGFloat

        init(size: CGFloat) {
            let appKitFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let font = CTFontCreateWithName(appKitFont.fontName as CFString, size, nil)
            var glyphs: [Character: MeterGlyph] = [:]

            for character in " -0123456789CILNOPRTU" {
                guard let codeUnit = String(character).utf16.first else { continue }
                var characterCode = UniChar(codeUnit)
                var glyph = CGGlyph()
                guard CTFontGetGlyphsForCharacters(font, &characterCode, &glyph, 1) else { continue }
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
                glyphs[character] = MeterGlyph(
                    path: CTFontCreatePathForGlyph(font, glyph, nil),
                    advance: advance.width
                )
            }

            self.glyphs = glyphs
            fallbackAdvance = glyphs[" "]?.advance ?? size * 0.6
        }
    }

    private static let valueMeterFont = MeterFont(size: 9)
    private static let labelMeterFont = MeterFont(size: 10)

    private func position(_ amplitude: Float) -> CGFloat {
        let db = 20 * log10(max(CGFloat(amplitude), 0.001))
        return min(max((db + 60) / 60, 0), 1)
    }
}

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: Data(text.utf8)) }
}
