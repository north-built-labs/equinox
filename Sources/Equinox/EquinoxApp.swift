import EquinoxAudio
import EquinoxDSP
import SwiftUI

@MainActor
final class DebugModel: ObservableObject {
    let audio = AudioController()
    @Published var status: AudioStatus = .stopped
    @Published var bassTest = false { didSet { push() } }

    init() {
        audio.onStatusChange = { [weak self] in self?.status = $0 }
        audio.start()
        push()
    }

    func push() {
        var s = DSPSettings()
        s.bands = bassTest ? [EQBand(type: .lowShelf, frequency: 150, gainDB: 12, q: 0.7)] : []
        s.preampDB = bassTest ? -6 : 0
        audio.apply(s)
    }
}

@main
struct EquinoxApp: App {
    @StateObject private var model = DebugModel()

    var body: some Scene {
        MenuBarExtra("Equinox", systemImage: "waveform.circle") {
            Text(String(describing: model.status))
            Toggle("Bass test (+12 dB low shelf)", isOn: $model.bassTest)
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
