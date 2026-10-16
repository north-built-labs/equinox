import EquinoxAudio
import EquinoxCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case equalizer = "Equalizer", mixer = "Mixer", effects = "Effects", headphones = "Headphones", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .equalizer: "slider.vertical.3"
        case .mixer: "slider.horizontal.below.square.and.square.filled"
        case .effects: "wand.and.stars"
        case .headphones: "headphones"
        case .settings: "gearshape"
        }
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    var meters: MixerMeters
    @State private var page: Page = .equalizer
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in Label(p.rawValue, systemImage: p.icon).tag(p) }
                .navigationSplitViewColumnWidth(170)
        } detail: {
            ScrollView {
                switch page {
                case .equalizer: EqualizerPage(model: model, spectrum: spectrum)
                case .mixer: MixerPage(model: model, meters: meters)
                case .effects: EffectsPage(model: model)
                case .headphones: HeadphonesPage(model: model)
                case .settings: SettingsPage(model: model)
                }
            }
            .background(Theme.background)
        }
        .frame(minWidth: 860, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear { showOnboarding = !model.hasCompletedOnboarding }
        .sheet(isPresented: $showOnboarding) { OnboardingView(model: model, spectrum: spectrum) }
    }
}

struct EqualizerPage: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    @State private var selectedBandID: UUID?
    @State private var graphic = false

    init(model: AppModel, spectrum: SpectrumModel, selectedBandID: UUID? = nil) {
        self.model = model
        self.spectrum = spectrum
        _selectedBandID = State(initialValue: selectedBandID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR SOUND, SHAPED")
                        .font(.system(size: 10, weight: .semibold)).tracking(2)
                        .foregroundStyle(Theme.cyan)
                    Text("Equalizer").font(.system(size: 30, weight: .semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 7) {
                        StatusDot(status: model.status, enabled: model.isEnabled)
                        Text(model.currentDevice?.name ?? "No output selected")
                            .font(.callout).lineLimit(1)
                    }
                    Text("\(Int(model.sampleRate / 1000)) kHz · Stereo")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    PresetBar(model: model)
                    Spacer(minLength: 8)
                    Toggle("Enabled", isOn: $model.isEnabled)
                        .toggleStyle(.switch).tint(Theme.cyan).controlSize(.small)
                }
                .padding(18)
                Divider().overlay(.white.opacity(0.04))

                HStack {
                    Label("FREQUENCY RESPONSE", systemImage: "waveform.path")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Equalizer mode", selection: $graphic) {
                        Text("Parametric").tag(false)
                        Text("Graphic").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                .padding(.horizontal, 20).padding(.top, 18)

                EQCanvasView(model: model, spectrum: spectrum, selectedBandID: $selectedBandID)
                    .frame(height: 350)
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

                Divider().overlay(.white.opacity(0.04))
                Group {
                    if graphic {
                        GraphicEQView(model: model)
                    } else {
                        BandInspector(model: model, selectedBandID: $selectedBandID)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.025))
            }
            .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.025)))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Preamp").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%+.1f dB", model.preampDB))
                            .font(.system(size: 12, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.violet)
                    }
                    Slider(value: Binding(get: { model.preampDB }, set: { model.preampDB = ($0 * 2).rounded() / 2 }), in: -24...24)
                        .tint(Theme.violet)
                    Text("Leave headroom for boosted frequencies.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 100)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Output").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(model.isMuted ? "MUTED" : "PEAK LIMITED")
                            .font(.system(size: 9, weight: .medium)).tracking(1)
                            .foregroundStyle(model.isMuted ? Theme.amber : .secondary)
                    }
                    VolumeControl(model: model)
                    MeterView(spectrum: spectrum)
                    DisclosureGroup("Balance") { BalanceControl(model: model).padding(.top, 6) }
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
        }
        .padding(28)
    }

}

struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("General").font(.headline)
                Toggle("Launch Equinox at login", isOn: $model.launchAtLogin)
            }.frame(maxWidth: .infinity, alignment: .leading).glassCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("Updates").font(.headline)
                Text("You have Equinox \(model.currentVersion).").font(.callout)
                Toggle("Check for updates automatically", isOn: $model.checkForUpdatesAutomatically)
                HStack {
                    Button("Check Now") { Task { await model.checkForUpdates(userInitiated: true) } }
                    if let release = model.availableUpdate {
                        Button("Install \(release.version) & Relaunch") {
                            Task { if await model.installUpdate() { NSApp.terminate(nil) } }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isInstallingUpdate)
                        if model.isInstallingUpdate { ProgressView().controlSize(.small) }
                        Link("Release notes", destination: release.pageURL).font(.caption)
                    }
                }
                if let status = model.updateStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).glassCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("Audio").font(.headline)
                HStack {
                    StatusDot(status: model.status, enabled: model.isEnabled)
                    Text(statusText).font(.callout)
                }
                HStack {
                    Button("Restart Audio Engine") { model.restartAudio() }
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                }
                Text("Equinox needs “System Audio Recording” permission. If audio goes silent while Equinox is on, check that Equinox is enabled there.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).glassCard()

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber).glassCard()
            }
        }
        .padding(24)
    }

    private var statusText: String {
        switch model.status {
        case .running(let name, let rate): "Running on \(name) · \(Int(rate)) Hz"
        case .failed(let message): message
        case .stopped: "Stopped"
        }
    }
}
