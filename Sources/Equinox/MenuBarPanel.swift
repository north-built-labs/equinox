import EquinoxAudio
import EquinoxCore
import SwiftUI

struct StatusDot: View {
    var status: AudioStatus
    var enabled: Bool

    var color: Color {
        switch status {
        case .running: enabled ? .green : Theme.amber
        case .failed: .red
        case .stopped: .gray
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 4)
    }
}

struct MenuBarPanel: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    var meters: MixerMeters
    @Environment(\.openWindow) private var openWindow
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Equinox").font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.accent)
                StatusDot(status: model.status, enabled: model.isEnabled)
                Spacer()
                Toggle("", isOn: $model.isEnabled).toggleStyle(.switch).labelsHidden().tint(Theme.cyan)
            }

            if case .failed(let message) = model.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Picker(selection: Binding(get: { model.currentDevice?.uid ?? "" },
                                      set: { uid in if let d = model.devices.first(where: { $0.uid == uid }) { model.selectOutputDevice(d) } })) {
                ForEach(model.devices) { d in Text(d.name).tag(d.uid) }
            } label: { Image(systemName: "hifispeaker.2.fill") }
                .onAppear { model.refreshDevices() }

            EQCanvasView(model: model, spectrum: spectrum, interactive: false, selectedBandID: $selected)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .glassCard(cornerRadius: 14, padding: 4)

            PresetBar(model: model, compact: true)

            VStack(spacing: 8) {
                VolumeControl(model: model)
                MeterView(spectrum: spectrum)
            }
            .glassCard(cornerRadius: 14, padding: 12)

            CompactMixer(model: model, meters: meters)
                .glassCard(cornerRadius: 14, padding: 12)

            HStack {
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                } label: { Label("Open Equinox", systemImage: "macwindow") }
                Spacer()
                Button("Quit") { model.flushSave(); NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 360)
        .preferredColorScheme(.dark)
    }
}
