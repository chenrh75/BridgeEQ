import SwiftUI

struct EQCurveView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EQ Curve")
                        .font(.title2.bold())
                    Text("Total response including preamp and output gain")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.preset.globalBypass {
                    Label("EQ bypassed", systemImage: "pause.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(model.preset.bands.filter(\.enabled).count) active bands")
                        .foregroundStyle(.secondary)
                }
            }

            EQCurveChart(preset: model.preset)
                .accessibilityLabel("Equalizer frequency response curve")
        }
        .padding(18)
        .background(.background)
    }
}

private struct EQCurveChart: View {
    let preset: EQPreset

    private let frequencies: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    private let gains: [Double] = [-24, -12, 0, 12, 24]

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 48, y: 16, width: max(1, size.width - 64), height: max(1, size.height - 48))

            context.fill(
                Path(roundedRect: plot, cornerRadius: 8),
                with: .color(Color(nsColor: .controlBackgroundColor))
            )

            for gain in gains {
                let y = yPosition(for: gain, in: plot)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(gain == 0 ? .secondary.opacity(0.55) : .secondary.opacity(0.18)), lineWidth: gain == 0 ? 1.2 : 1)

                let label = context.resolve(Text("\(Int(gain))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary))
                context.draw(label, at: CGPoint(x: plot.minX - 7, y: y), anchor: .trailing)
            }

            for frequency in frequencies {
                let x = xPosition(for: frequency, in: plot)
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(.secondary.opacity(0.16)), lineWidth: 1)

                if [20, 100, 1_000, 10_000, 20_000].contains(frequency) {
                    let label = context.resolve(Text(frequencyLabel(frequency)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary))
                    context.draw(label, at: CGPoint(x: x, y: plot.maxY + 8), anchor: .top)
                }
            }

            var fill = Path()
            var stroke = Path()
            let zeroDB = yPosition(for: 0, in: plot)
            let response = EQResponse(preset: preset)
            let sampleCount = max(300, Int(plot.width))
            for index in 0...sampleCount {
                let fraction = Double(index) / Double(sampleCount)
                let frequency = 20 * pow(1_000, fraction)
                let gain = response.gain(at: frequency)
                let point = CGPoint(
                    x: plot.minX + plot.width * fraction,
                    y: yPosition(for: gain, in: plot)
                )
                if index == 0 {
                    stroke.move(to: point)
                    fill.move(to: CGPoint(x: point.x, y: zeroDB))
                    fill.addLine(to: point)
                } else {
                    stroke.addLine(to: point)
                    fill.addLine(to: point)
                }
            }
            fill.addLine(to: CGPoint(x: plot.maxX, y: zeroDB))
            fill.closeSubpath()

            context.clip(to: Path(roundedRect: plot, cornerRadius: 8))
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [.accentColor.opacity(0.28), .accentColor.opacity(0.025)]),
                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                endPoint: CGPoint(x: plot.midX, y: plot.maxY)
            ))
            context.stroke(stroke, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }

    private func xPosition(for frequency: Double, in rect: CGRect) -> CGFloat {
        rect.minX + rect.width * log10(frequency / 20) / 3
    }

    private func yPosition(for gain: Double, in rect: CGRect) -> CGFloat {
        rect.midY - rect.height * CGFloat(gain / 48)
    }

    private func frequencyLabel(_ frequency: Double) -> String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
    }
}

private struct EQResponse {
    private static let sampleRate = 48_000.0
    private let baseGain: Double
    private let filters: [Biquad]

    init(preset: EQPreset) {
        baseGain = preset.outputGain + (preset.globalBypass ? 0 : preset.preamp)
        filters = preset.globalBypass ? [] : preset.bands.compactMap { band in
            guard band.enabled else { return nil }
            if band.type != .lowPass && band.type != .highPass && abs(band.gain) <= 0.0001 { return nil }
            return Biquad(band: band)
        }
    }

    func gain(at frequency: Double) -> Double {
        guard !filters.isEmpty else { return baseGain }
        let omega = 2 * Double.pi * min(frequency, Self.sampleRate / 2 - 1) / Self.sampleRate
        let z1 = Complex(cos(omega), -sin(omega))
        let z2 = z1 * z1
        var result = baseGain
        for filter in filters {
            result += filter.magnitude(z1: z1, z2: z2)
        }
        return result
    }
}

private struct Biquad {
    private let b0: Double, b1: Double, b2: Double
    private let a0: Double, a1: Double, a2: Double

    init(band: EQBand) {
        let sampleRate = 48_000.0
        let center = min(max(band.frequency, 10), sampleRate / 2 - 1)
        let q = min(max(band.q, 0.1), 20)
        let omega = 2 * Double.pi * center / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * q)
        let a = pow(10, band.gain / 40)
        let sqrtA = sqrt(a)

        let coefficients: (Double, Double, Double, Double, Double, Double)
        switch band.type {
        case .parametric:
            coefficients = (1 + alpha * a, -2 * cosOmega, 1 - alpha * a,
                            1 + alpha / a, -2 * cosOmega, 1 - alpha / a)
        case .lowShelf:
            coefficients = (
                a * ((a + 1) - (a - 1) * cosOmega + 2 * sqrtA * alpha),
                2 * a * ((a - 1) - (a + 1) * cosOmega),
                a * ((a + 1) - (a - 1) * cosOmega - 2 * sqrtA * alpha),
                (a + 1) + (a - 1) * cosOmega + 2 * sqrtA * alpha,
                -2 * ((a - 1) + (a + 1) * cosOmega),
                (a + 1) + (a - 1) * cosOmega - 2 * sqrtA * alpha
            )
        case .highShelf:
            coefficients = (
                a * ((a + 1) + (a - 1) * cosOmega + 2 * sqrtA * alpha),
                -2 * a * ((a - 1) + (a + 1) * cosOmega),
                a * ((a + 1) + (a - 1) * cosOmega - 2 * sqrtA * alpha),
                (a + 1) - (a - 1) * cosOmega + 2 * sqrtA * alpha,
                2 * ((a - 1) - (a + 1) * cosOmega),
                (a + 1) - (a - 1) * cosOmega - 2 * sqrtA * alpha
            )
        case .lowPass:
            coefficients = ((1 - cosOmega) / 2, 1 - cosOmega, (1 - cosOmega) / 2,
                            1 + alpha, -2 * cosOmega, 1 - alpha)
        case .highPass:
            coefficients = ((1 + cosOmega) / 2, -(1 + cosOmega), (1 + cosOmega) / 2,
                            1 + alpha, -2 * cosOmega, 1 - alpha)
        }
        (b0, b1, b2, a0, a1, a2) = coefficients
    }

    func magnitude(z1: Complex, z2: Complex) -> Double {
        let numerator = Complex(b0, 0) + z1 * b1 + z2 * b2
        let denominator = Complex(a0, 0) + z1 * a1 + z2 * a2
        return 20 * log10(max(numerator.magnitude / max(denominator.magnitude, 1e-12), 1e-12))
    }
}

private struct Complex {
    let real: Double
    let imaginary: Double

    init(_ real: Double, _ imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }

    var magnitude: Double { hypot(real, imaginary) }

    static func + (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real + rhs.real, lhs.imaginary + rhs.imaginary)
    }

    static func * (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
                lhs.real * rhs.imaginary + lhs.imaginary * rhs.real)
    }

    static func * (lhs: Complex, rhs: Double) -> Complex {
        Complex(lhs.real * rhs, lhs.imaginary * rhs)
    }
}
