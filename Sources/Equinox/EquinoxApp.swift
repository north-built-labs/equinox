import EquinoxAudio
import EquinoxCore
import SwiftUI

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    let model: AppModel
    let spectrum: SpectrumModel

    private init() {
        let model = AppModel(audio: AudioController())
        self.model = model
        spectrum = SpectrumModel(tap: model.analysis, sampleRate: { [weak model] in model?.sampleRate ?? 48_000 })
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
            MenuBarPanel(model: env.model, spectrum: env.spectrum)
        } label: {
            Image(systemName: env.model.isEnabled ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Equinox", id: "main") {
            MainWindow(model: env.model, spectrum: env.spectrum)
        }
        .defaultLaunchBehavior(env.model.hasCompletedOnboarding ? .suppressed : .presented)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 720)
    }
}
