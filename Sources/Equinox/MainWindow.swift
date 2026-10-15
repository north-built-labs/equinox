import EquinoxAudio
import EquinoxCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case equalizer = "Equalizer", settings = "Settings"
    var id: String { rawValue }
    var icon: String { self == .equalizer ? "slider.vertical.3" : "gearshape" }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PresetBar(model: model)
                Spacer()
                StatusDot(status: model.status, enabled: model.isEnabled)
                Toggle("Enabled", isOn: $model.isEnabled).toggleStyle(.switch).tint(Theme.cyan)
            }

            VStack(alignment: .leading, spacing: 14) {
                EQCanvasView(model: model, spectrum: spectrum, selectedBandID: $selectedBandID)
                    .frame(height: 320)
                Picker("", selection: $graphic) {
                    Text("Parametric").tag(false)
                    Text("Graphic").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                if graphic { GraphicEQView(model: model) } else { BandInspector(model: model, selectedBandID: $selectedBandID) }
            }
            .glassCard(cornerRadius: 20, padding: 18)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Preamp").font(.headline)
                    HStack {
                        Slider(value: Binding(get: { model.preampDB }, set: { model.preampDB = ($0 * 2).rounded() / 2 }), in: -24...24)
                            .tint(Theme.violet)
                        Text(String(format: "%+.1f dB", model.preampDB))
                            .font(.system(size: 12, design: .rounded).monospacedDigit()).frame(width: 64, alignment: .trailing)
                    }
                    Text("Lower the preamp when boosting bands to keep headroom. The limiter catches anything above 0 dB.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Output").font(.headline)
                    VolumeControl(model: model)
                    BalanceControl(model: model)
                    MeterView(spectrum: spectrum)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            }
        }
        .padding(24)
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
