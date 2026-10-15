import AppKit
import EquinoxAudio
import EquinoxCore
import EquinoxDSP
import SwiftUI

/// Renders real app screens offscreen (our own windows, so no screen-recording permission) to PNGs.
@MainActor
enum Snapshots {
    static func render(to dir: URL) -> Never {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-snapshots-\(UUID().uuidString)")
            let audio = PreviewAudio()
            let model = AppModel(audio: audio, store: Store(directory: storeDir), loginItem: PreviewLoginItem())
            model.completeOnboarding()
            model.selectPreset(Preset.builtIns[4].id)   // Loudness
            let notch = model.addBand(frequency: 3200, gainDB: -5)
            model.boostDB = 4.5

            let spectrum = SpectrumModel(tap: model.analysis, sampleRate: { 48_000 })
            spectrum.freeze(levels: spectrum.frequencies.map { f in
                // Music-like slope: strong lows, rolling off, with a little texture.
                Float(-18 - 9 * log2(max(f, 40) / 60) + 4 * sin(f / 37))
            }, peakLeft: 0.55, peakRight: 0.48)

            let bg = Theme.background
            save("menubar", MenuBarPanel(model: model, spectrum: spectrum).background(bg), dir)
            save("equalizer", EqualizerPage(model: model, spectrum: spectrum, selectedBandID: notch)
                .frame(width: 900).background(bg), dir)
            save("graphic", GraphicEQView(model: model).padding(18).frame(width: 760).glassCard().padding(24).background(bg), dir)
            save("settings", SettingsPage(model: model).frame(width: 760).background(bg), dir)
            save("onboarding", OnboardingView(model: model, spectrum: spectrum).background(bg), dir)
            save("main-window", MainWindow(model: model, spectrum: spectrum), dir, size: CGSize(width: 1100, height: 900))
            try? FileManager.default.removeItem(at: storeDir)
        }
        exit(0)
    }

    private static func save<V: View>(_ name: String, _ view: V, _ dir: URL, size: CGSize? = nil) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame.size = size ?? host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: host.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png \(Int(host.frame.width))x\(Int(host.frame.height))")
        }
        window.orderOut(nil)
    }
}

/// Audio stand-in for rendering: reports a running device, does nothing else.
@MainActor
final class PreviewAudio: AudioControlling {
    var onStatusChange: ((AudioStatus) -> Void)?
    var onOutputDeviceChange: ((AudioDevice) -> Void)?
    var onHardwareVolumeChange: ((Float) -> Void)?
    let analysis = AnalysisTap()
    private let devices = [AudioDevice(id: 1, uid: "speakers", name: "MacBook Pro Speakers", transportType: 0),
                           AudioDevice(id: 2, uid: "airpods", name: "AirPods Pro", transportType: 0)]

    func start() {
        onStatusChange?(.running(deviceName: devices[0].name, sampleRate: 48_000))
        onOutputDeviceChange?(devices[0])
        onHardwareVolumeChange?(0.7)
    }
    func stop() {}
    func restart() {}
    func apply(_ settings: DSPSettings) {}
    func outputDevices() -> [AudioDevice] { devices }
    func selectOutputDevice(_ device: AudioDevice) {}
    func setHardwareVolume(_ volume: Float) -> Bool { true }
}

final class PreviewLoginItem: LoginItemControlling {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
