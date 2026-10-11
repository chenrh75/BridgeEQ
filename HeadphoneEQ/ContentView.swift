import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CoreText

enum BridgeEQLayout {
    static let gap: CGFloat = 8
    static let detailGap: CGFloat = 4
    static let pageInset: CGFloat = 16
    static let sectionInset: CGFloat = 0
    static let typeWidth: CGFloat = 130
    static let numberWidth: CGFloat = 92
    static let rowHeight: CGFloat = 28
    static let windowWidth: CGFloat = 522
    static let tableWidth: CGFloat = windowWidth - 2 * pageInset
    static let automaticBandLimit = 5
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var presetName = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var presetToDelete: EQPreset?
    @State private var namingPreset = false
    @State private var confirmingReplace = false
    @FocusState private var presetNameFocused: Bool
    @State private var windowChromeHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            RouterHeader(router: model.router, toggle: model.toggle)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, BridgeEQLayout.pageInset)
                .padding(.vertical, 2)
            Divider()
            VStack(alignment: .leading, spacing: BridgeEQLayout.pageInset) {
                devices
                controls
                presets
                Divider()
                bands
            }
            .padding(.horizontal, BridgeEQLayout.pageInset)
            .padding(.top, BridgeEQLayout.pageInset)
            .padding(.bottom, 22)
        }
        .background(.background)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: WindowLayoutMetricsKey.self,
                                       value: WindowLayoutMetrics(contentHeight: geometry.size.height))
            }
        }
        .onPreferenceChange(WindowLayoutMetricsKey.self) { metrics in
            if let content = metrics.contentHeight, let list = metrics.listHeight {
                windowChromeHeight = content - list
            }
        }
        .background(BandWindowSizing(bandCount: model.preset.bands.count,
                                     contentHeight: windowChromeHeight + bandListHeight,
                                     hasMeasurements: windowChromeHeight > 0))
        .sheet(isPresented: $namingPreset) { presetNamingSheet }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.router.stop()
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
        HStack(spacing: BridgeEQLayout.gap) {
            Text("Output").fixedSize()
            CompactPicker(selection: $model.outputUID, options: model.outputs.map { ($0.uid, $0.label) }, accessibilityLabel: "Output device")
                .frame(maxWidth: .infinity).frame(height: BridgeEQLayout.rowHeight)
                .help(model.selectedOutput?.label ?? "Choose an output device")
            Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh devices").accessibilityLabel("Refresh devices")
        }
    }

    private var controls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Toggle("Bypass EQ", isOn: $model.preset.globalBypass).fixedSize()
            Spacer(minLength: 20)
            LabeledNumber(label: "Preamp", value: $model.preset.preamp, range: -24...12, suffix: "dB")
            Spacer(minLength: 20)
            LabeledNumber(label: "Output", value: $model.preset.outputGain, range: -24...12, suffix: "dB")
        }
    }

    private var bands: some View {
        UtilitySection {
            if model.preset.bands.isEmpty {
                Text("No EQ bands. Use Add band to create one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: BridgeEQLayout.rowHeight,
                           idealHeight: BridgeEQLayout.rowHeight,
                           maxHeight: .infinity, alignment: .topLeading)
                    .background(bandViewportMeasurement)
            } else {
                VStack(spacing: BridgeEQLayout.detailGap) {
                    bandColumns {
                        Color.clear.frame(width: 20, height: 1)
                        ForEach(["Type", "Frequency · Hz", "Gain · dB", "Q"], id: \.self) { title in
                            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.leading, title == "Type" ? BridgeEQLayout.gap : 0)
                                .padding(.trailing, title == "Type" ? 0 : BridgeEQLayout.detailGap)
                                .lineLimit(1)
                                .frame(width: title == "Type" ? BridgeEQLayout.typeWidth : BridgeEQLayout.numberWidth, alignment: title == "Type" ? .leading : .trailing)
                        }
                        Color.clear.frame(width: 24, height: 1)
                    }
                    ScrollView {
                        LazyVStack(spacing: BridgeEQLayout.gap) {
                            ForEach($model.preset.bands) { $band in
                                bandColumns {
                                    Toggle("Enable band", isOn: $band.enabled).labelsHidden().frame(width: 20)
                                    CompactPicker(selection: $band.type, options: EQFilterType.allCases.map { ($0, $0.title) }, accessibilityLabel: "Type")
                                        .frame(width: BridgeEQLayout.typeWidth, height: BridgeEQLayout.rowHeight)
                                    LabeledNumber(label: "Frequency", value: $band.frequency, range: 10...24000, suffix: "Hz", showsLabel: false)
                                        .frame(width: BridgeEQLayout.numberWidth, alignment: .leading)
                                    LabeledNumber(label: "Gain", value: $band.gain, range: -24...24, suffix: "dB", showsLabel: false)
                                        .frame(width: BridgeEQLayout.numberWidth, alignment: .leading)
                                    LabeledNumber(label: "Q", value: $band.q, range: 0.1...20, suffix: "", showsLabel: false)
                                        .frame(width: BridgeEQLayout.numberWidth, alignment: .leading)
                                    Button(role: .destructive) { model.deleteBand(band.id) } label: {
                                        Image(systemName: "trash").frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete band").accessibilityLabel("Delete band")
                                }
                            }
                        }
                        .padding(.top, BridgeEQLayout.detailGap)
                    }
                    .scrollIndicators(.visible)
                    .frame(minHeight: BridgeEQLayout.rowHeight + BridgeEQLayout.gap,
                           idealHeight: bandListHeight,
                           maxHeight: .infinity)
                    .background(bandViewportMeasurement)
                }
                .padding(.horizontal, BridgeEQLayout.sectionInset)
            }
        } label: {
            HStack(spacing: BridgeEQLayout.gap) {
                Text("EQ bands").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("EQ curve", systemImage: "chart.xyaxis.line") { openWindow(id: "eq-curve") }.controlSize(.small)
                Button("Add band", systemImage: "plus") { model.addBand() }.controlSize(.small)
            }.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var bandListHeight: CGFloat {
        if model.preset.bands.isEmpty { return BridgeEQLayout.rowHeight }
        return max(BridgeEQLayout.rowHeight + BridgeEQLayout.gap,
                   CGFloat(min(model.preset.bands.count, BridgeEQLayout.automaticBandLimit))
                   * (BridgeEQLayout.rowHeight + BridgeEQLayout.gap) - BridgeEQLayout.detailGap)
    }

    private var bandViewportMeasurement: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: WindowLayoutMetricsKey.self,
                                   value: WindowLayoutMetrics(listHeight: geometry.size.height))
        }
    }

    private func bandColumns<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: BridgeEQLayout.gap, content: content)
            .frame(width: BridgeEQLayout.tableWidth, alignment: .leading)
    }

    private var savedPreset: EQPreset? {
        model.presets.first { $0.id == model.preset.id }
    }

    private var presetSelection: Binding<UUID?> {
        Binding(get: { savedPreset?.id }, set: { id in
            if let preset = model.presets.first(where: { $0.id == id }) { model.load(preset) }
        })
    }

    private var presets: some View {
        HStack(spacing: BridgeEQLayout.gap) {
            Text("Preset").fixedSize()
            CompactPicker(selection: presetSelection,
                          options: (savedPreset == nil ? [(nil, "Current settings")] : [])
                            + model.presets.map { (Optional($0.id), $0.name) },
                          accessibilityLabel: "Preset")
                .frame(maxWidth: .infinity).frame(height: BridgeEQLayout.rowHeight)
                .disabled(model.presets.isEmpty)
                .help(savedPreset?.name ?? "Current unsaved settings")
            Button("Save") {
                if let savedPreset { model.savePreset(named: savedPreset.name) }
                else { beginSaveAs() }
            }
            Menu {
                Button("Save As…") { beginSaveAs() }
                Menu("Delete preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name, role: .destructive) { presetToDelete = preset }
                    }
                }.disabled(model.presets.isEmpty)
                Divider()
                Button("Import APO / AutoEQ…") { importing = true }
                Button("Export…") { exporting = true }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help("Preset actions").accessibilityLabel("Preset actions")
        }
    }

    private func beginSaveAs() {
        presetName = model.preset.name == "Flat" ? "" : model.preset.name
        namingPreset = true
    }

    private func saveNamedPreset() {
        model.savePreset(named: presetName.trimmingCharacters(in: .whitespacesAndNewlines))
        namingPreset = false
    }

    private var presetNamingSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save preset").font(.headline)
            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Preset name")
                .focused($presetNameFocused)
            HStack(spacing: BridgeEQLayout.gap) {
                Spacer()
                Button("Cancel") { namingPreset = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if model.presets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                        confirmingReplace = true
                    } else { saveNamedPreset() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
        .onAppear { presetNameFocused = true }
        .alert("Replace existing preset?", isPresented: $confirmingReplace) {
            Button("Cancel", role: .cancel) { }
            Button("Replace", role: .destructive) { saveNamedPreset() }
        } message: {
            Text("A preset named “\(presetName.trimmingCharacters(in: .whitespacesAndNewlines))” already exists.")
        }
    }

}

private struct UtilitySection<Content: View, Heading: View>: View {
    let content: Content
    let heading: Heading
    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Heading) {
        self.content = content()
        self.heading = label()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BridgeEQLayout.gap) {
            heading
            content
        }
    }
}

private struct RouterHeader: View {
    @ObservedObject var router: AudioRouter
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: BridgeEQLayout.gap) {
            Text(router.recovering ? "Reconnecting…" : router.running ? "Processing" : "Stopped")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .help(router.status).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            MeterDisplay(meters: router.meters)
                .frame(width: 282, height: 38).fixedSize()
            Button(router.running || router.recovering ? "Stop" : "Start", action: toggle)
                .buttonStyle(.bordered)
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
    var showsLabel = true
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
        HStack(spacing: BridgeEQLayout.detailGap) {
            if showsLabel { Text(label).foregroundStyle(.secondary) }
            TextField(label, value: $value, formatter: Self.decimalFormatter)
                .frame(width: BridgeEQLayout.numberWidth)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
            if showsLabel && !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
        .fixedSize()
    }
}

// Explicit native popup geometry keeps menu edges aligned with column headings.
private struct CompactPicker<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled
    let options: [(Value, String)]
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = true
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: proposal.height ?? BridgeEQLayout.rowHeight)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != options.map({ $0.1 }) {
            button.removeAllItems()
            button.addItems(withTitles: options.map { $0.1 })
        }
        if let index = options.firstIndex(where: { $0.0 == selection }) { button.selectItem(at: index) }
        button.isEnabled = isEnabled && !options.isEmpty
    }

    final class Coordinator: NSObject {
        var parent: CompactPicker
        init(_ parent: CompactPicker) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].0
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

// Measure the fixed chrome separately from the flexible band viewport.
private struct WindowLayoutMetrics: Equatable {
    var contentHeight: CGFloat?
    var listHeight: CGFloat?
}

private struct WindowLayoutMetricsKey: PreferenceKey {
    static var defaultValue = WindowLayoutMetrics()
    static func reduce(value: inout WindowLayoutMetrics, nextValue: () -> WindowLayoutMetrics) {
        let next = nextValue()
        value.contentHeight = next.contentHeight ?? value.contentHeight
        value.listHeight = next.listHeight ?? value.listHeight
    }
}

// SwiftUI updates its minimum size when rows disappear, but does not grow the
// native window when rows are added. Apply a bounded ideal height in both cases.
private struct BandWindowSizing: NSViewRepresentable {
    let bandCount: Int
    let contentHeight: CGFloat
    let hasMeasurements: Bool

    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ view: SizingView, context: Context) {
        view.bandCount = bandCount
        view.targetHeight = contentHeight
        view.hasMeasurements = hasMeasurements
        view.scheduleResize()
    }

    final class SizingView: NSView {
        var bandCount = 0
        var targetHeight: CGFloat = 0
        var hasMeasurements = false
        private var appliedCount: Int?
        private var userSized = false
        private var startingHeight: CGFloat = 0
        private var pending = false
        private var applyingResize = false
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            appliedCount = nil
            userSized = false
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                self?.startingHeight = window?.frame.height ?? 0
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window else { return }
                if abs(window.frame.height - self.startingHeight) > 1 { self.userSized = true }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window, self.hasMeasurements,
                      self.appliedCount == self.bandCount,
                      !self.applyingResize, !window.inLiveResize else { return }
                // Also respect enlargement through the native Zoom action.
                self.userSized = true
            })
            scheduleResize()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func scheduleResize() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                guard let window = self.window, self.hasMeasurements,
                      self.appliedCount != self.bandCount else { return }
                self.appliedCount = self.bandCount
                // Respect a height explicitly chosen by the user for this window.
                guard !self.userSized, !window.inLiveResize else { return }
                // SwiftUI geometry excludes the title-bar safe area even when
                // AppKit uses a full-size content view. Include that chrome.
                let titleHeight = window.frame.height - window.contentLayoutRect.height
                var frame = window.frame
                frame.size.height = max(300, self.targetHeight) + titleHeight
                frame.size.height = min(frame.height, window.screen?.visibleFrame.height ?? frame.height)
                frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
                if abs(window.frame.height - frame.height) > 1 {
                    self.applyingResize = true
                    window.setFrame(frame, display: true)
                    self.applyingResize = false
                }
            }
        }
    }
}
