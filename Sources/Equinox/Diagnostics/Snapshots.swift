import AVFoundation
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
            let model = AppModel(audio: audio, store: Store(directory: storeDir), loginItem: PreviewLoginItem(), runningApps: PreviewRunningApps(),
                                 autoEQ: PreviewAutoEQ(), updates: PreviewUpdates())
            model.completeOnboarding()
            model.selectPreset(Preset.builtIns[4].id)   // Loudness
            let notch = model.addBand(frequency: 3200, gainDB: -5)
            model.boostDB = 4.5
            model.setStripVolume(1.3, for: "com.apple.Music")
            model.setStripPreset(Preset.builtIns[1].id, for: "com.apple.Music")
            model.setStripVolume(0.45, for: "com.google.Chrome")
            model.setStripMuted(true, for: "us.zoom.xos")
            let meters = MixerMeters(model: model)
            _ = model.addEffect(.builtIn(.reverb))
            let comp = model.addEffect(.builtIn(.compressor))
            model.setEffectEnabled(comp, false)
            if let bp = PluginCatalog.installedEffects().first(where: { $0.name.contains("AUBandpass") }) {
                _ = model.addEffect(.audioUnit(bp))
            }
            meters.freeze(["": 0.35, "com.apple.Music": 0.8, "com.google.Chrome": 0.3])

            let spectrum = SpectrumModel(tap: model.analysis, sampleRate: { 48_000 })
            spectrum.freeze(levels: spectrum.frequencies.map { f in
                // Music-like slope: strong lows, rolling off, with a little texture.
                Float(-18 - 9 * log2(max(f, 40) / 60) + 4 * sin(f / 37))
            }, peakLeft: 0.55, peakRight: 0.48)

            let bg = Theme.background
            save("menubar", MenuBarPanel(model: model, spectrum: spectrum, meters: meters).background(bg), dir)
            save("equalizer", EqualizerPage(model: model, spectrum: spectrum, selectedBandID: notch)
                .frame(width: 900).background(bg), dir)
            save("graphic", GraphicEQView(model: model).padding(18).frame(width: 760).glassCard().padding(24).background(bg), dir)
            save("mixer", MixerPage(model: model, meters: meters).frame(width: 900).background(bg), dir)
            save("effects", EffectsPage(model: model).frame(width: 900).background(bg), dir)
            // Parameter trees are only populated once a unit is attached to an engine (as in a real chain).
            let editorEngine = AVAudioEngine()
            let reverb = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_Reverb2,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            editorEngine.attach(reverb)
            save("effect-editor", GenericParameterView(unit: reverb.auAudioUnit).frame(width: 420, height: 520), dir)
            func await_(_ work: @escaping @MainActor () async -> Void) {
                var done = false
                Task { @MainActor in await work(); done = true }
                while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            }
            await_ { await model.searchAutoEQ("airpods pro") }
            await_ { await model.applyAutoEQ(model.autoEQResults[0]) }
            model.updateHeadphones { $0.crossfeed = .medium }
            await_ { await model.checkForUpdates(userInitiated: true) }
            save("headphones", HeadphonesPage(model: model).frame(width: 900).background(bg), dir)
            save("settings", SettingsPage(model: model).frame(width: 760).background(bg), dir)
            save("onboarding", OnboardingView(model: model, spectrum: spectrum).background(bg), dir)
            save("main-window", MainWindow(model: model, spectrum: spectrum, meters: meters), dir, size: CGSize(width: 1100, height: 680))
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
    var onProcessesChange: (([AudioProcessInfo]) -> Void)?
    let stripMeters = StripMeters()
    var processes: [AudioProcessInfo] = [
        AudioProcessInfo(objectID: 31, pid: 31, bundleID: "com.apple.Music", executableName: "Music", isRunningOutput: true),
        AudioProcessInfo(objectID: 32, pid: 32, bundleID: "com.google.Chrome.helper", executableName: "Helper", isRunningOutput: true),
        AudioProcessInfo(objectID: 33, pid: 33, bundleID: "us.zoom.xos", executableName: "zoom.us", isRunningOutput: false),
        AudioProcessInfo(objectID: 34, pid: 34, bundleID: "", executableName: "afplay", isRunningOutput: true),
    ]
    var activeStripKeys: [String] = ["", "com.apple.Music", "com.google.Chrome"]
    var dedicated: [DedicatedStrip] = []
    func audioProcesses() -> [AudioProcessInfo] { processes }
    func setDedicatedStrips(_ strips: [DedicatedStrip]) { dedicated = strips }
    var spatial: SpatialParameters?
    func setSpatial(_ p: SpatialParameters?) { spatial = p }
    var effects: [EffectSlot] = []
    var effectStates: [UUID: Data] = [:]
    var onEffectParametersChanged: (() -> Void)?
    var onEffectsChainChanged: (() -> Void)?
    func setEffects(_ slots: [EffectSlot], reload: Bool) { effects = slots }
    func effectUnit(for id: UUID) -> AUAudioUnit? { nil }
    func captureEffectStates() -> [UUID: Data] { effectStates }
    func installedPlugins() -> [AudioUnitID] { PluginCatalog.installedEffects() }
    private let devices = [AudioDevice(id: 1, uid: "airpods", name: "AirPods Pro", transportType: 0, isHeadphones: true),
                           AudioDevice(id: 2, uid: "speakers", name: "MacBook Pro Speakers", transportType: 0)]

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

final class PreviewRunningApps: RunningAppsProviding {
    func runningApps() -> [RunningAppInfo] {
        [RunningAppInfo(bundleID: "com.apple.Music", name: "Music"),
         RunningAppInfo(bundleID: "com.google.Chrome", name: "Google Chrome"),
         RunningAppInfo(bundleID: "us.zoom.xos", name: "zoom.us")]
    }
}

final class PreviewAutoEQ: AutoEQProviding {
    func entries() async throws -> [AutoEQEntry] {
        [AutoEQEntry(name: "Apple AirPods Pro", source: "crinacle", rig: "711", path: "./crinacle/711%20in-ear/Apple%20AirPods%20Pro"),
         AutoEQEntry(name: "Apple AirPods Pro", source: "Super Review", rig: nil, path: "./Super%20Review/in-ear/Apple%20AirPods%20Pro"),
         AutoEQEntry(name: "Apple AirPods Pro 2", source: "crinacle", rig: "711", path: "./crinacle/711%20in-ear/Apple%20AirPods%20Pro%202")]
    }
    func profile(for entry: AutoEQEntry) async throws -> CorrectionProfile {
        CorrectionProfile(name: entry.name, source: entry.source, preampDB: -5.2, bands: [
            EQBand(type: .lowShelf, frequency: 105, gainDB: 3.5, q: 0.7), EQBand(type: .peak, frequency: 2800, gainDB: -4, q: 1.8),
            EQBand(type: .peak, frequency: 6200, gainDB: 5, q: 2.5), EQBand(type: .highShelf, frequency: 10000, gainDB: -2, q: 0.7)])
    }
}

final class PreviewUpdates: UpdateProviding {
    func latestRelease() async throws -> ReleaseInfo {
        ReleaseInfo(version: "0.5.0", downloadURL: URL(string: "https://github.com/north-built-labs/equinox/releases/download/v0.5.0/Equinox-macos.zip")!,
                    signatureURL: URL(string: "https://github.com/north-built-labs/equinox/releases/download/v0.5.0/Equinox-macos.zip.sig")!,
                    pageURL: URL(string: "https://github.com/north-built-labs/equinox/releases")!)
    }
}
