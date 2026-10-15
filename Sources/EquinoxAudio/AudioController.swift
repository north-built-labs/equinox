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
    var onProcessesChange: (([AudioProcessInfo]) -> Void)? { get set }
    var stripMeters: StripMeters { get }
    /// Strip keys of the running session, in meter/tap order.
    var activeStripKeys: [String] { get }
    func audioProcesses() -> [AudioProcessInfo]
    /// Apps that need their own tap. Changing the set rebuilds the session (debounced).
    func setDedicatedStrips(_ strips: [DedicatedStrip])
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
    private var stall = StallMonitor()
    private var sessionStartNanos: UInt64 = 0

    public var onProcessesChange: (([AudioProcessInfo]) -> Void)?
    public var stripMeters: StripMeters { renderer.stripMeters }
    public var activeStripKeys: [String] { session?.stripKeys ?? [] }
    private var dedicated: [DedicatedStrip] = []
    private var processSnapshot: [AudioProcessInfo] = []
    private var processPoll: Timer?

    public func audioProcesses() -> [AudioProcessInfo] { AudioSystem.audioProcesses() }

    public func setDedicatedStrips(_ strips: [DedicatedStrip]) {
        guard strips != dedicated else { return }
        dedicated = strips
        if session != nil { scheduleRebuild() }
    }

    private func pollProcesses() {
        let now = AudioSystem.audioProcesses()
        guard now != processSnapshot else { return }
        processSnapshot = now
        onProcessesChange?(now)
    }

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
                try? PropertyListener(object: .system, selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
                    MainActor.assumeIsolated { self?.pollProcesses() }
                },
            ].compactMap { $0 }
        }
        rebuild()
        startWatchdog()
        pollProcesses()
        processPoll?.invalidate()
        processPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollProcesses() }
        }
    }

    public func stop() {
        wantsRunning = false
        rebuildTask?.cancel()
        watchdog?.invalidate(); watchdog = nil
        processPoll?.invalidate(); processPoll = nil
        tearDown()
        status = .stopped
    }

    public func restart() {
        stall.reset()
        if wantsRunning { rebuild() } else { start() }
    }

    public func apply(_ settings: DSPSettings) {
        self.settings = settings
        if let session { renderer.submit(DSPConfig(settings: settings, sampleRate: session.sampleRate, stripOrder: session.stripKeys)) }
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
        stall.reset()   // device/format events give a stalled engine a fresh retry budget
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
            let newSession = try TapSession(outputDeviceID: deviceID, excludedProcesses: [ownProcess],
                                            dedicated: dedicated, renderer: renderer)
            renderer.submit(DSPConfig(settings: settings, sampleRate: newSession.sampleRate, stripOrder: newSession.stripKeys))
            try newSession.start()
            session = newSession
            sessionStartNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
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
                switch self.stall.evaluate(now: now, lastCallback: self.renderer.lastCallbackNanos(),
                                           sessionStart: self.sessionStartNanos) {
                case .healthy:
                    break
                case .rebuild:
                    Self.log.warning("Audio callback stalled; rebuilding (attempt \(self.stall.retries))")
                    self.rebuild()
                case .giveUp:
                    Self.log.error("Audio device not responding; pausing processing")
                    self.tearDown()
                    self.status = .failed("Audio device isn’t responding. Equinox paused processing so your audio plays normally, and will retry when the output device changes.")
                }
            }
        }
    }
}
