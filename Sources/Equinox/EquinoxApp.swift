import EquinoxAudio
import EquinoxCore
import SwiftUI

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    let model: AppModel
    let spectrum: SpectrumModel
    let meters: MixerMeters

    private init() {
        let pluginGuard = PluginGuard(directory: Store.defaultDirectory)
        let crashed = pluginGuard.takeCrashedPlugins()
        let model = AppModel(audio: AudioController(pluginGuard: pluginGuard), crashedPlugins: crashed)
        self.model = model
        spectrum = SpectrumModel(tap: model.analysis, sampleRate: { [weak model] in model?.sampleRate ?? 48_000 })
        meters = MixerMeters(model: model)
        model.onEffectsChainChanged = { [weak model] in
            if let model { PluginWindows.shared.revalidate(model) }
        }
        model.launch()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnvironment.shared.model.flushSave() }
    }
}

struct EquinoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let env = AppEnvironment.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: env.model, spectrum: env.spectrum, meters: env.meters)
        } label: {
            Image(systemName: env.model.isEnabled ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Equinox", id: "main") {
            MainWindow(model: env.model, spectrum: env.spectrum, meters: env.meters)
        }
        .defaultLaunchBehavior(env.model.hasCompletedOnboarding ? .suppressed : .presented)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 720)
    }
}
