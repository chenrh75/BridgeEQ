// Build with swiftc, then pass the built BridgeEQ.app path. Plays a quiet
// synthetic signal from a separate process so the global tap must capture it.
import Foundation
import AVFoundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: RouteSignalCheck /absolute/path/BridgeEQ.app")
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let toneURL = temporary.appendingPathComponent("tone.wav")
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 10)!
tone.frameLength = tone.frameCapacity
for index in 0..<Int(tone.frameLength) {
    // -40 dBFS, with short fades to avoid clicks.
    let fade = min(1.0, Double(min(index, Int(tone.frameLength) - 1 - index)) / 480)
    let value = Float(0.01 * fade * sin(2 * .pi * 1000 * Double(index) / 48000))
    tone.floatChannelData![0][index] = value
    tone.floatChannelData![1][index] = value
}
do {
    var fileSettings = format.settings
    fileSettings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: toneURL, settings: fileSettings)
    try file.write(from: tone)
}
let producer = Process()
producer.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
producer.arguments = [toneURL.path]
try producer.run()
defer { if producer.isRunning { producer.terminate(); producer.waitUntilExit() } }
let app = Process()
app.executableURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/MacOS/BridgeEQ")
app.arguments = ["--smoke-test-route"]
app.environment = ProcessInfo.processInfo.environment.merging([
    "BRIDGEEQ_ROUTE_TEST_SECONDS": "5", "BRIDGEEQ_SMOKE_REQUIRE_AUDIO": "1"
]) { _, new in new }
try app.run()
let deadline = Date().addingTimeInterval(20)
while app.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
if app.isRunning {
    app.terminate()
    app.waitUntilExit()
    fputs("Signal check timed out; check the system audio permission prompt.\n", stderr)
    exit(2)
}
exit(app.terminationStatus)
