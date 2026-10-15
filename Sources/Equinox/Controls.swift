import EquinoxCore
import EquinoxDSP
import SwiftUI

/// Horizontal slider 0...2 where 0...1 is volume and 1...2 is boost (0...+12 dB, tinted amber).
struct VolumeControl: View {
    @Bindable var model: AppModel

    private var combined: Double {
        model.boostDB > 0 ? 1 + model.boostDB / DSPSettings.maxBoostDB : model.volume
    }

    private func setCombined(_ v: Double) {
        if v <= 1 { model.boostDB = 0; model.volume = max(v, 0) }
        else { if model.volume != 1 { model.volume = 1 }; model.boostDB = ((v - 1) * DSPSettings.maxBoostDB * 2).rounded() / 2 }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.isMuted.toggle() } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18).foregroundStyle(model.isMuted ? .red : .white.opacity(0.8))
            }.buttonStyle(.plain)
            GeometryReader { geo in
                let w = geo.size.width, t = CGFloat(combined / 2)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(Theme.amber.opacity(0.15)).frame(width: w / 2).offset(x: w / 2)
                    Capsule().fill(model.boostDB > 0
                        ? AnyShapeStyle(LinearGradient(colors: [Theme.cyan, Theme.violet, Theme.amber], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Theme.accent))
                        .frame(width: max(w * t, 6))
                    Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 3).offset(x: w * t - 7)
                }
                .frame(height: 6).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    var value = Double(min(max(v.location.x / w, 0), 1)) * 2
                    if abs(value - 1) < 0.03 { value = 1 }   // detent at 100%
                    setCombined(value)
                })
            }
            .frame(height: 20)
            Text(model.boostDB > 0 ? String(format: "+%.1f dB", model.boostDB) : "\(Int((model.volume * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(model.boostDB > 0 ? Theme.amber : .white.opacity(0.8))
                .frame(width: 58, alignment: .trailing)
        }
    }
}

struct BalanceControl: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("L").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.balance },
                                  set: { model.balance = abs($0) < 0.05 ? 0 : $0 }), in: -1...1)
                .tint(Theme.cyan)
            Text("R").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
    }
}

struct MeterView: View {
    var spectrum: SpectrumModel

    var body: some View {
        VStack(spacing: 3) {
            bar(spectrum.peakLeft)
            bar(spectrum.peakRight)
        }
        .onAppear { spectrum.attach() }
        .onDisappear { spectrum.detach() }
    }

    private func bar(_ peak: Float) -> some View {
        GeometryReader { geo in
            let db = Decibels.fromLinear(Double(peak))
            let t = CGFloat(min(max((db + 60) / 60, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule().fill(LinearGradient(colors: [Theme.cyan, Theme.violet, db > -1 ? .red : Theme.violet],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * t)
            }
        }
        .frame(height: 4)
    }
}

/// Vertical slider used by the graphic EQ. `value` within `range`, zero line highlighted.
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let zeroT = CGFloat((0 - range.lowerBound) / (range.upperBound - range.lowerBound))
            let y = h * (1 - t), zeroY = h * (1 - zeroT)
            ZStack(alignment: .top) {
                Capsule().fill(.white.opacity(0.08)).frame(width: 6)
                Rectangle().fill(tint.opacity(0.9)).frame(width: 6, height: abs(zeroY - y)).offset(y: min(y, zeroY))
                Circle().fill(.white).frame(width: 16, height: 16).shadow(color: tint.opacity(0.8), radius: 6).offset(y: y - 8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let tt = 1 - Double(min(max(v.location.y / h, 0), 1))
                value = ((range.lowerBound + tt * (range.upperBound - range.lowerBound)) * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}
