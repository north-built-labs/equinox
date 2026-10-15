import AudioToolbox
import CoreAudio
import EquinoxDSP
import Foundation
import os

public enum AudioStatus: Equatable, Sendable {
    case stopped
    case running(deviceName: String, sampleRate: Double)
    case failed(String)

    public var isRunning: Bool { if case .running = self { true } else { false } }
}

@MainActor
public protocol AudioControlling: AnyObject {
    var onStatusChange: ((AudioStatus) -> Void)? { get set }
    var onOutputDeviceChange: ((AudioDevice) -> Void)? { get set }
    var onHardwareVolumeChange: ((Float) -> Void)? { get set }
    var analysis: AnalysisTap { get }
    func start()
    func stop()
    func restart()
    func apply(_ settings: DSPSettings)
    func outputDevices() -> [AudioDevice]
    func selectOutputDevice(_ device: AudioDevice)
    /// Returns false when the current device has no settable hardware volume.
    func setHardwareVolume(_ volume: Float) -> Bool
}

@MainActor
public final class AudioController: AudioControlling {
    private static let log = Logger(subsystem: "com.pie.equinox", category: "audio")

    public var onStatusChange: ((AudioStatus) -> Void)?
    public var onOutputDeviceChange: ((AudioDevice) -> Void)?
    public var onHardwareVolumeChange: ((Float) -> Void)?
    public private(set) var status: AudioStatus = .stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public let renderer = Renderer()
    public var analysis: AnalysisTap { renderer.analysis }

    private var session: TapSession?
    private var settings = DSPSettings()
    private var wantsRunning = false
    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []
    private var rebuildTask: Task<Void, Never>?
    private var watchdog: Timer?

    public init() {}

    public func start() {
        wantsRunning = true
        if systemListeners.isEmpty {
            systemListeners = [
                try? PropertyListener(object: .system, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleRebuild() }
                },
                try? PropertyListener(object: .system, selector: kAudioHardwarePropertyDevices) { [weak self] in
                    MainActor.assumeIsolated { self?.devicesChanged() }
                },
            ].compactMap { $0 }
        }
        rebuild()
        startWatchdog()
    }

    public func stop() {
        wantsRunning = false
        rebuildTask?.cancel()
        watchdog?.invalidate(); watchdog = nil
        tearDown()
        status = .stopped
    }

    public func restart() { if wantsRunning { rebuild() } else { start() } }

    public func apply(_ settings: DSPSettings) {
        self.settings = settings
        if let session { renderer.submit(DSPConfig(settings: settings, sampleRate: session.sampleRate)) }
    }

    public func outputDevices() -> [AudioDevice] { AudioSystem.outputDevices() }

    public func selectOutputDevice(_ device: AudioDevice) {
        do { try AudioSystem.setDefaultOutputDevice(device.id) }   // listener triggers the rebuild
        catch { Self.log.error("Select output failed: \(String(describing: error))") }
    }

    public func setHardwareVolume(_ volume: Float) -> Bool {
        guard let id = session?.outputDeviceID ?? (try? AudioSystem.defaultOutputDevice()) else { return false }
        return AudioSystem.setHardwareVolume(id, volume)
    }

    // MARK: - Session lifecycle

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    private func devicesChanged() {
        guard let session else { return }
        if !AudioSystem.outputDevices().contains(where: { $0.id == session.outputDeviceID }) { scheduleRebuild() }
    }

    private func tearDown() {
        deviceListeners = []
        session?.invalidate()
        session = nil
    }

    private func rebuild() {
        tearDown()
        guard wantsRunning else { return }
        do {
            let deviceID = try AudioSystem.defaultOutputDevice()
            let device = try AudioSystem.describe(deviceID)
            let ownProcess = try AudioSystem.processObject(forPID: getpid())
            let newSession = try TapSession(outputDeviceID: deviceID, excludedProcesses: [ownProcess], renderer: renderer)
            renderer.submit(DSPConfig(settings: settings, sampleRate: newSession.sampleRate))
            try newSession.start()
            session = newSession
            deviceListeners = [
                try? PropertyListener(object: deviceID, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleRebuild() }
                },
                try? PropertyListener(object: deviceID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                      scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                    MainActor.assumeIsolated {
                        if let v = AudioSystem.hardwareVolume(deviceID) { self?.onHardwareVolumeChange?(v) }
                    }
                },
            ].compactMap { $0 }
            status = .running(deviceName: device.name, sampleRate: newSession.sampleRate)
            onOutputDeviceChange?(device)
            if let v = AudioSystem.hardwareVolume(deviceID) { onHardwareVolumeChange?(v) }
            Self.log.info("Running on \(device.name) @ \(newSession.sampleRate) Hz")
        } catch {
            tearDown()
            status = .failed(String(describing: error))
            Self.log.error("Start failed: \(String(describing: error))")
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning, self.session != nil else { return }
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let last = self.renderer.lastCallbackNanos()
                if last != 0, now > last, now - last > 2_000_000_000 {
                    Self.log.warning("Audio callback stalled; rebuilding")
                    self.rebuild()
                }
            }
        }
    }
}
