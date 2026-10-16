import EquinoxCore
import EquinoxDSP
import SwiftUI

struct ListeningPage: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel

    private var active: Bool {
        guard model.isEnabled, model.listening.isEnabled else { return false }
        if case .running = model.status { return true }
        return false
    }

    private var activity: ListeningActivity { active ? spectrum.listening : ListeningActivity() }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SETTLE INTO YOUR SOUND")
                        .font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Theme.cyan)
                    Text("Listening").font(.system(size: 30, weight: .semibold))
                }
                Spacer()
                Label(active ? "Listening is on" : "Listening is off", systemImage: active ? "waveform" : "pause.circle")
                    .font(.callout).foregroundStyle(active ? Theme.cyan : .secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep everything comfortable.").font(.title3.weight(.semibold))
                        Text("Smooth out volume differences and soften frequencies when they get loud.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Listening", isOn: $model.listening.isEnabled)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.cyan)
                        .accessibilityLabel("Enable Listening")
                }
                Divider().overlay(.white.opacity(0.04))
                HStack {
                    PresetBar(model: model)
                    Spacer()
                    Text("All apps · Saved with your preset").font(.caption).foregroundStyle(.secondary)
                }
                if !model.isEnabled {
                    HStack {
                        Label("Equinox is bypassed.", systemImage: "pause.circle").foregroundStyle(Theme.amber)
                        Spacer()
                        Button("Enable Equinox") { model.isEnabled = true }
                    }.font(.callout)
                }
            }
            .glassCard(padding: 20)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Consistent volume", systemImage: "waveform.path")
                        .font(.headline)
                    Spacer()
                    Toggle("Consistent volume", isOn: $model.listening.levelsEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.cyan)
                        .accessibilityLabel("Consistent volume")
                }
                Text("Gently brings quiet audio up and loud audio down. Your output volume stays in your hands.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Target level")
                            Spacer()
                            Text(String(format: "%.0f dBFS", model.listening.targetDB)).monospacedDigit()
                                .foregroundStyle(Theme.cyan)
                        }.font(.callout)
                        Slider(value: $model.listening.targetDB, in: -30...(-14), step: 1)
                            .tint(Theme.cyan).accessibilityLabel("Target level in dBFS")
                        endpointLabels("Quieter", "Fuller")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Preserve dynamics")
                            Spacer()
                            Text(model.listening.preserveDynamics, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(Theme.violet)
                        }.font(.callout)
                        Slider(value: $model.listening.preserveDynamics, in: 0...1)
                            .tint(Theme.violet).accessibilityLabel("Preserve dynamics")
                        endpointLabels("More even", "More expressive")
                    }
                }
                .disabled(!model.listening.levelsEnabled)
                Text("Quiet pauses are left alone. Automatic gain is limited to +6 dB. Target uses average signal level; final loudness also depends on your output volume.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .glassCard(padding: 20)

            VStack(alignment: .leading, spacing: 14) {
                Label("Reactive EQ", systemImage: "slider.horizontal.3").font(.headline)
                Text("Each control sets the maximum cut. Frequencies ease back as their energy falls.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 18) {
                    bandControl("Control bass", detail: "Boom and rumble · 120 Hz", amount: $model.listening.bass,
                                reduction: activity.bassDB, color: Theme.cyan)
                    bandControl("Tame harshness", detail: "Sharp edges · 3.2 kHz", amount: $model.listening.harshness,
                                reduction: activity.harshnessDB, color: Theme.violet)
                    bandControl("Soften sibilance", detail: "Hissing S sounds · 7 kHz", amount: $model.listening.sibilance,
                                reduction: activity.sibilanceDB, color: Theme.amber)
                }
            }
            .glassCard(padding: 20)

            HStack(spacing: 20) {
                Image(systemName: "waveform.path.ecg").font(.title2).foregroundStyle(Theme.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live level adjustment").font(.callout.weight(.semibold))
                    Text(active ? "The change being applied before your output volume." : "Enable Listening to hear and see its adjustments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%+.1f dB", activity.gainDB))
                    .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.cyan)
                    .accessibilityLabel("Live level adjustment")
                    .accessibilityValue(String(format: "%+.1f decibels", activity.gainDB))
            }
            .glassCard(padding: 20)
        }
        .padding(28)
        .onAppear { spectrum.attach() }
        .onDisappear { spectrum.detach() }
    }

    private func endpointLabels(_ left: String, _ right: String) -> some View {
        HStack { Text(left); Spacer(); Text(right) }.font(.caption2).foregroundStyle(.secondary)
    }

    private func bandControl(_ title: String, detail: String, amount: Binding<Double>, reduction: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Slider(value: amount, in: 0...1).tint(color).accessibilityLabel(title)
            HStack {
                Text(amount.wrappedValue == 0 ? "Off" : String(format: "Up to %.1f dB", amount.wrappedValue * 9))
                Spacer(minLength: 2)
                Text(String(format: "−%.1f", reduction)).monospacedDigit().foregroundStyle(color)
            }.font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    Capsule().fill(color).frame(width: geometry.size.width * CGFloat(min(max(reduction / 9, 0), 1)))
                }
            }
            .frame(height: 4)
            .accessibilityLabel("\(title) reduction")
            .accessibilityValue(String(format: "%.1f decibels", reduction))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
