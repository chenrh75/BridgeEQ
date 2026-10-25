import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CoreText
import QuartzCore

enum BridgeEQLayout {
    static let gap: CGFloat = 8
    static let detailGap: CGFloat = 4
    static let pageInset: CGFloat = 16
    static let sectionInset: CGFloat = 0
    static let typeWidth: CGFloat = 130
    static let numberWidth: CGFloat = 92
    static let rowHeight: CGFloat = 28
    static let actionLabelWidth: CGFloat = 52
    static let actionLabelHeight: CGFloat = 18
    static let windowWidth: CGFloat = 522
    static let tableWidth: CGFloat = windowWidth - 2 * pageInset
    static let automaticBandLimit = 5
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var launchAtLogin = LaunchAtLogin()
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
            RouterHeader(router: model.router, processingRequested: model.processingRequested,
                         noEQ: model.outputEQRule == .noEQ || (model.outputEQRule == .global && model.globalPreset == nil),
                         toggle: model.toggle)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, BridgeEQLayout.pageInset)
                .padding(.vertical, 2)
            Divider()
            VStack(alignment: .leading, spacing: BridgeEQLayout.pageInset) {
                devices
                presets
                controls
                Divider()
                bands
                startupOption
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
        .onAppear { launchAtLogin.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { launchAtLogin.refresh() }
        }
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

    private var startupOption: some View {
        HStack(spacing: BridgeEQLayout.gap) {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.enabled },
                set: { enabled in
                    do { try launchAtLogin.setEnabled(enabled) }
                    catch { model.errorMessage = "Could not change launch at login: \(error.localizedDescription)" }
                }
            ))
            .fixedSize()
            .help("Open BridgeEQ automatically when you log in to your Mac.")
            Spacer()
            if launchAtLogin.needsApproval {
                Text("Approval needed").foregroundStyle(.secondary)
                Button("Open Settings…") { launchAtLogin.openSettings() }
                    .controlSize(.small)
            }
        }
        .font(.system(size: 12))
    }

    private var devices: some View {
        HStack(spacing: BridgeEQLayout.gap) {
            Text("Output").fixedSize()
            CompactPicker(selection: Binding(get: { model.outputUID }, set: { model.selectOutput($0) }),
                          options: model.outputs.map { ($0.uid, $0.label) }, accessibilityLabel: "Output device")
                .frame(maxWidth: .infinity).frame(height: BridgeEQLayout.rowHeight)
                .help(model.selectedOutput?.label ?? "Choose an output device")
            outputEQRule
            Button { model.refreshDevices() } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: BridgeEQLayout.actionLabelWidth, height: BridgeEQLayout.actionLabelHeight)
            }
                .buttonStyle(.bordered)
                .help("Refresh devices").accessibilityLabel("Refresh devices")
        }
    }

    private var outputEQRule: some View {
        CompactPicker(selection: Binding(
            get: { model.outputEQRule },
            set: { model.setOutputEQRule($0) }
        ), options: OutputEQRule.allCases.map { ($0, $0.title) }, accessibilityLabel: "Output EQ rule")
        .frame(width: 128, height: BridgeEQLayout.rowHeight)
        .disabled(model.selectedOutput == nil)
        .help("For \(model.selectedOutput?.name ?? "this output"): use the global preset, bind the selected preset, or play without EQ. No EQ overrides all presets.")
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
        Binding(get: { model.outputEQRule == .global ? model.globalPreset?.id : savedPreset?.id }, set: { id in
            if model.outputEQRule == .global {
                if let preset = model.globalPresets.first(where: { $0.id == id }) { model.load(preset) }
                else { model.setGlobalPreset(nil) }
            } else if let preset = model.presets.first(where: { $0.id == id }) { model.load(preset) }
        })
    }

    private var presets: some View {
        HStack(spacing: BridgeEQLayout.gap) {
            Text("Preset").fixedSize()
            CompactPicker(selection: presetSelection,
                          options: model.outputEQRule == .global
                            ? [(nil, "No EQ")] + model.globalPresets.map { (Optional($0.id), $0.name) }
                            : (savedPreset == nil ? [(nil, "Current settings")] : [])
                                + model.presets.map { (Optional($0.id), $0.name) },
                          accessibilityLabel: "Preset")
                .frame(maxWidth: .infinity).frame(height: BridgeEQLayout.rowHeight)
                .disabled(model.outputEQRule != .global && model.presets.isEmpty)
                .help(model.outputEQRule == .global
                      ? "Global fallback: \(model.globalPreset?.name ?? "No EQ")"
                      : savedPreset?.name ?? "Current unsaved settings")
            Menu("Save…") {
                Button("Save") {
                    if let savedPreset { model.savePreset(named: savedPreset.name) }
                    else { beginSaveAs() }
                }
                Button("Save As…") { beginSaveAs() }
                Divider()
                Menu("Global fallback") {
                    Button(model.globalPreset == nil ? "✓ No EQ" : "No EQ") { model.setGlobalPreset(nil) }
                    ForEach(model.globalPresets) { preset in
                        Button((model.globalPreset?.id == preset.id ? "✓ " : "") + preset.name) { model.setGlobalPreset(preset) }
                    }
                }
                Divider()
                Button("Import…") { importing = true }
                Button("Export…") { exporting = true }
                Button("Delete…", role: .destructive) { presetToDelete = savedPreset }
                    .disabled(savedPreset == nil)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .accessibilityLabel("Save and preset actions")
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
    let processingRequested: Bool
    let noEQ: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: BridgeEQLayout.gap) {
            Text(noEQ ? "No EQ" : router.recovering ? "Reconnecting…" : router.running ? "Processing" : processingRequested ? "No preset" : "Stopped")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .help(noEQ ? "Audio plays without EQ on this output." : router.status).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            MeterDisplay(meters: router.meters)
                .frame(width: 282, height: 38).fixedSize()
            Button(action: toggle) {
                Text(processingRequested || router.running || router.recovering ? "Stop" : "Start")
                    .frame(width: BridgeEQLayout.actionLabelWidth, height: BridgeEQLayout.actionLabelHeight)
            }
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
        view.model = nil
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
            let value = parent.options[index].0
            guard value != parent.selection else { return }
            parent.selection = value
        }
    }
}

private final class MeterView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureMeterLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMeterLayers()
    }

    // Retain the opaque hold markers above the changing bar artwork. Their
    // backing is reused by the compositor until their positions change.
    private let holdLayers = (0..<4).map { _ in CALayer() }
    private let trackLayers = (0..<4).map { _ in CALayer() }
    private let fillLayers = (0..<4).map { _ in CALayer() }
    private let staticLabelsLayer = CAShapeLayer()
    private func configureMeterLayers() {
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let labels = CGMutablePath()
        for (text, x, y, font) in [("IN", 0.0, 25.0, Self.labelMeterFont),
                                    ("OUT", 143.0, 25.0, Self.labelMeterFont),
                                    ("L", 0.0, 14.0, Self.valueMeterFont),
                                    ("R", 0.0, 2.0, Self.valueMeterFont),
                                    ("L", 143.0, 14.0, Self.valueMeterFont),
                                    ("R", 143.0, 2.0, Self.valueMeterFont)] {
            labels.addPath(font.path(for: text), transform: CGAffineTransform(translationX: x, y: y))
        }
        staticLabelsLayer.path = labels
        staticLabelsLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        staticLabelsLayer.frame = NSRect(x: 0, y: 0, width: 282, height: 38)
        layer?.addSublayer(staticLabelsLayer)
        for index in holdLayers.indices {
            let bar = barRect(index)
            let track = trackLayers[index]
            track.frame = bar
            track.cornerRadius = bar.height / 2
            layer?.addSublayer(track)
            let fill = fillLayers[index]
            fill.anchorPoint = .zero
            fill.position = bar.origin
            fill.bounds = NSRect(x: 0, y: 0, width: channels[index].width, height: bar.height)
            fill.cornerRadius = min(bar.height, channels[index].width) / 2
            layer?.addSublayer(fill)
            let marker = holdLayers[index]
            marker.backgroundColor = NSColor.white.cgColor
            marker.frame = holdRect(index, channel: channels[index])
            layer?.addSublayer(marker)
        }
        CATransaction.commit()
        updateMeterColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMeterColors()
    }

    private func updateMeterColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            staticLabelsLayer.fillColor = NSColor.secondaryLabelColor.cgColor
            for index in trackLayers.indices {
                trackLayers[index].backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
                fillLayers[index].backgroundColor = (channels[index].clipped ? NSColor.systemRed : NSColor.systemGreen).cgColor
            }
        }
        CATransaction.commit()
    }

    private var visibilityObservers = [NSObjectProtocol]()
    weak var model: MeterModel? {
        didSet {
            if oldValue !== model { oldValue?.setDisplayVisible(self, false) }
            updateMeterVisibility()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        visibilityObservers.forEach { center.removeObserver($0) }
        visibilityObservers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                visibilityObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    // Enter through the main queue instead of checking the Swift
                    // executor inherited from an AppKit notification callback.
                    DispatchQueue.main.async { [weak self, weak window] in
                        guard let self, let window, self.window === window else { return }
                        self.updateMeterVisibility()
                    }
                })
            }
            visibilityObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    self.model?.setDisplayVisible(self, false)
                }
            })
        }
        updateMeterVisibility()
    }

    override func viewDidHide() { super.viewDidHide(); updateMeterVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMeterVisibility() }

    private func updateMeterVisibility() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        model?.setDisplayVisible(self, visible && !isHiddenOrHasHiddenAncestor)
    }

    deinit { visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) } }
    var state = MeterState() {
        didSet {
            guard state != oldValue || numericUpdatePending else { return }
            updateChannels(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private var lastNumericUpdate: TimeInterval?
    private var numericUpdatePending = false
    private func updateChannels(at now: TimeInterval) {
        let reset = state == MeterState()
        let refreshNumbers = reset || (lastNumericUpdate.map { now - $0 >= 0.1 - 0.000001 } ?? true)
        numericUpdatePending = !refreshNumbers
        if refreshNumbers { lastNumericUpdate = now }
        let next = renderedChannels(refreshNumbers: refreshNumbers)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in next.indices {
            let previous = channels[index]
            let current = next[index]
            if current.width != previous.width {
                fillLayers[index].bounds.size.width = current.width
                let radius = min(barRect(index).height, current.width) / 2
                if fillLayers[index].cornerRadius != radius {
                    fillLayers[index].cornerRadius = radius
                }
            }
            if current.clipped != previous.clipped {
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    fillLayers[index].backgroundColor = (current.clipped ? NSColor.systemRed : NSColor.systemGreen).cgColor
                }
            }
            if current.holdX != previous.holdX {
                holdLayers[index].frame = holdRect(index, channel: current)
            }
            if current.text != previous.text || current.clipped != previous.clipped {
                setNeedsDisplay(numberRect(index))
            }
        }
        CATransaction.commit()
        channels = next
    }

    // The audio model retains full precision. Bar changes update retained
    // rectangles; only numeric changes invalidate the view's drawing.
    // Bars follow every model update; numeric labels refresh at most 10 Hz.
    // Clip transitions and a full reset bypass the numeric throttle.
    private struct Channel: Equatable {
        var width: CGFloat = 0
        var holdX: CGFloat = 0
        var text = "-60"
        var clipped = false
    }
    private var channels = [Channel](repeating: Channel(), count: 4)

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        staticLabelsLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateChannels(at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }

    private func renderedChannels(refreshNumbers: Bool) -> [Channel] {
        let scale = window?.backingScaleFactor ?? 2
        func channel(_ index: Int, _ value: Float, _ hold: Float, _ clipped: Bool) -> Channel {
            let refresh = refreshNumbers || clipped != channels[index].clipped
            let text = refresh ? (clipped ? "CLIP" : String(format: "%3.0f", 20 * log10(max(Double(value), 0.001)))) : channels[index].text
            return Channel(width: (92 * position(value) * scale).rounded() / scale,
                    holdX: (min(90, max(0, 92 * position(hold) - 1)) * scale).rounded() / scale,
                    text: text,
                    clipped: clipped)
        }
        return [channel(0, state.inputLeft, state.inputLeftHold, state.inputLeftClips),
                channel(1, state.inputRight, state.inputRightHold, state.inputRightClips),
                channel(2, state.outputLeft, state.outputLeftHold, state.outputLeftClips),
                channel(3, state.outputRight, state.outputRightHold, state.outputRightClips)]
    }

    private func channelRect(_ index: Int) -> NSRect {
        NSRect(x: index < 2 ? 0 : 143, y: index.isMultiple(of: 2) ? 13 : 1, width: 139, height: 12)
    }

    private func barRect(_ index: Int) -> NSRect {
        NSRect(x: (index < 2 ? 0 : 143) + 13, y: index.isMultiple(of: 2) ? 14 : 2, width: 92, height: 7)
    }

    private func numberRect(_ index: Int) -> NSRect {
        NSRect(x: (index < 2 ? 0 : 143) + 109, y: index.isMultiple(of: 2) ? 13 : 1, width: 30, height: 12)
    }

    private func holdRect(_ index: Int, channel: Channel) -> NSRect {
        let bar = barRect(index)
        return NSRect(x: bar.minX + channel.holdX, y: bar.minY, width: 2, height: bar.height)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 282, height: 38) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for index in channels.indices where needsToDraw(channelRect(index)) {
            drawChannel(index, channel: channels[index],
                        x: index < 2 ? 0 : 143, y: index.isMultiple(of: 2) ? 14 : 2)
        }
    }

    private func drawChannel(_ index: Int, channel: Channel, x: CGFloat, y: CGFloat) {
        if needsToDraw(numberRect(index)) {
            drawText(channel.text, at: CGPoint(x: x + 109, y: y), color: channel.clipped ? .systemRed : .secondaryLabelColor, size: 9)
        }
    }

    private func drawText(_ text: String, at point: CGPoint, color: NSColor, size: CGFloat) {
        // Draw cached glyph outlines instead of creating attributed strings.
        // This keeps the macOS 27 CoreText attribute-dictionary crash out of
        // the meter's continuously-redrawn path while retaining crisp text.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let font = size >= 10 ? Self.labelMeterFont : Self.valueMeterFont
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.beginPath()
        context.addPath(font.path(for: text))
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
        private var textPaths = [String: CGPath]()

        func path(for text: String) -> CGPath {
            if let cached = textPaths[text] { return cached }
            let path = CGMutablePath()
            var x: CGFloat = 0
            for character in text {
                guard let glyph = glyphs[character] else {
                    x += fallbackAdvance
                    continue
                }
                if let outline = glyph.path {
                    path.addPath(outline, transform: CGAffineTransform(translationX: x, y: 0))
                }
                x += glyph.advance
            }
            // Numeric levels have a small practical vocabulary. Bound the
            // cache even if unusual input contains extreme Float amplitudes.
            if textPaths.count < 128 { textPaths[text] = path }
            return path
        }

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
