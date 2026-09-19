import Foundation
import AVFoundation

enum EQFilterType: String, Codable, CaseIterable, Identifiable {
    case parametric, lowShelf, highShelf, lowPass, highPass
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "Shelf", with: " shelf").replacingOccurrences(of: "Pass", with: " pass").capitalized }
    var avType: AVAudioUnitEQFilterType {
        switch self {
        case .parametric: .parametric
        case .lowShelf: .lowShelf
        case .highShelf: .highShelf
        case .lowPass: .lowPass
        case .highPass: .highPass
        }
    }
}

struct EQBand: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var type: EQFilterType = .parametric
    var frequency: Double = 1000
    var gain: Double = 0
    var q: Double = 1.0
}

struct EQPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var preamp: Double = 0
    var outputGain: Double = 0
    var globalBypass = false
    var bands: [EQBand]

    static let flat = EQPreset(name: "Flat", bands: [80, 250, 1000, 4000, 10000].map { EQBand(frequency: Double($0)) })
}

struct AudioDevice: Identifiable, Hashable {
    let id: UInt32
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    var label: String { "\(name) · \(inputChannels) in / \(outputChannels) out" }
}

struct MeterState: Equatable {
    var inputLeft: Float = 0, inputRight: Float = 0
    var outputLeft: Float = 0, outputRight: Float = 0
    var inputLeftHold: Float = 0, inputRightHold: Float = 0
    var outputLeftHold: Float = 0, outputRightHold: Float = 0
    var inputLeftClips = false, inputRightClips = false
    var outputLeftClips = false, outputRightClips = false
}
