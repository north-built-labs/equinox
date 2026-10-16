import AudioToolbox
import AVFoundation
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
    /// Effect chain in order. Same slots with different enablement are toggled live; anything else rebuilds,
    /// carrying live parameters over — unless `reload`, which rebuilds from the slots' stored state.
    func setEffects(_ slots: [EffectSlot], reload: Bool)
    /// A chain parameter changed (user edit, plugin UI, automation). Main actor.
    var onEffectParametersChanged: (() -> Void)? { get set }
    /// A new chain was installed (units changed). Main actor.
    var onEffectsChainChanged: (() -> Void)? { get set }
    func effectUnit(for id: UUID) -> AUAudioUnit?
    func captureEffectStates() -> [UUID: Data]
    func installedPlugins() -> [AudioUnitID]
    /// Spatial (HRTF) renderer parameters; nil removes it. Parameter changes apply live.
    func setSpatial(_ parameters: SpatialParameters?)
}

@MainActor
public final class AudioController: AudioControlling {
    private static let log = Logger(subsystem: "com.northbuiltlabs.equinox", category: "audio")

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
    /// Increments on every successful session build (diagnostics).
    public private(set) var sessionGeneration = 0
    private var dedicated: [DedicatedStrip] = []
    private var processSnapshot: [AudioProcessInfo] = []
    private var processPoll: Timer?

    public func audioProcesses() -> [AudioProcessInfo] { AudioSystem.audioProcesses() }

    public func setDedicatedStrips(_ strips: [DedicatedStrip]) {
        guard strips != dedicated else { return }
        dedicated = strips
        // Same apps, different processes (a helper started/exited): retarget the taps in place, no rebuild.
        if let session, session.updateProcesses(strips) {
            Self.log.info("Updated tap processes in place")
            return
        }
        // Retry even after a failure: a corrected strip list may succeed.
        if wantsRunning { scheduleRebuild() }
    }

    private func pollProcesses() {
        let now = AudioSystem.audioProcesses()
        guard now != processSnapshot else { return }
        processSnapshot = now
        onProcessesChange?(now)
    }

    private let pluginGuard: PluginGuard?
    private var effectSlots: [EffectSlot] = []
    private var chain: EffectsChain?
    private var chainBuild = 0

    public init(pluginGuard: PluginGuard? = nil) { self.pluginGuard = pluginGuard }

    public var onEffectParametersChanged: (() -> Void)?
    public var onEffectsChainChanged: (() -> Void)?

    public func setEffects(_ slots: [EffectSlot], reload: Bool = false) {
        effectSlots = slots
        if !reload, let chain, chain.slots.map(\.id) == slots.map(\.id), chain.slots.map(\.kind) == slots.map(\.kind) {
            chainBuild += 1   // the current chain already matches: cancel any in-flight build for an older request
            for s in slots { chain.setBypassed(s.id, !s.isEnabled) }
            return
        }
        buildChain(carryLiveState: !reload)
    }

    public func effectUnit(for id: UUID) -> AUAudioUnit? { chain?.unit(for: id) }
    public func captureEffectStates() -> [UUID: Data] { chain?.captureStates() ?? [:] }
    public func installedPlugins() -> [AudioUnitID] { PluginCatalog.installedEffects() }

    private var spatial: SpatialRenderer?
    private var spatialParameters: SpatialParameters?

    public func setSpatial(_ parameters: SpatialParameters?) {
        spatialParameters = parameters
        guard let parameters else {
            if spatial != nil { spatial = nil; renderer.submitSpatial(nil) }
            return
        }
        let rate = session?.sampleRate ?? 48_000
        if let spatial, spatial.sampleRate == rate { spatial.set(parameters); return }
        spatial = try? SpatialRenderer(sampleRate: rate, parameters: parameters)
        renderer.submitSpatial(spatial)
    }

    /// Builds a new chain off the audio thread, carrying live parameter state over; the newest build wins.
    private func buildChain(carryLiveState: Bool = true) {
        chainBuild += 1
        let build = chainBuild
        let rate = session?.sampleRate ?? chain?.sampleRate ?? 48_000
        let live = carryLiveState ? chain?.captureStates() ?? [:] : [:]
        let slots = effectSlots.map { slot -> EffectSlot in
            var s = slot
            if let state = live[s.id] { s.state = state }
            return s
        }
        let loader = EffectLoader(pluginGuard: pluginGuard)
        Task { @MainActor [weak self] in
            let built = slots.isEmpty ? nil : try? await EffectsChain.make(slots: slots, sampleRate: rate, loader: loader)
            guard let self, build == self.chainBuild else { return }
            built?.observeParameters { [weak self] in self?.onEffectParametersChanged?() }
            self.chain = built
            self.renderer.submitEffects(built)
            self.onEffectsChainChanged?()
        }
    }

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

    /// Make-before-break: the next session's taps and aggregate are created while the current one keeps
    /// running; only then is the old IO stopped and the new one started. The old taps stay alive (muting their
    /// processes) until the new IO runs, so a rebuild never lets unprocessed audio through.
    private func rebuild() {
        guard wantsRunning else { tearDown(); return }
        let old = session
        do {
            let deviceID = try AudioSystem.defaultOutputDevice()
            let device = try AudioSystem.describe(deviceID)
            let ownProcess = try AudioSystem.processObject(forPID: getpid())
            let live = Set(AudioSystem.audioProcesses().map(\.objectID))
            let strips = dedicated.map { DedicatedStrip(key: $0.key, processes: $0.processes.filter(live.contains)) }
            let newSession = try TapSession(outputDeviceID: deviceID, excludedProcesses: [ownProcess], dedicated: strips)

            deviceListeners = []
            old?.stopIO()
            do {
                try newSession.prepare(renderer: renderer)
                renderer.submit(DSPConfig(settings: settings, sampleRate: newSession.sampleRate, stripOrder: newSession.stripKeys))
                if let chain, chain.sampleRate == newSession.sampleRate { renderer.submitEffects(chain) }
                if let params = spatialParameters {
                    if spatial?.sampleRate != newSession.sampleRate {
                        spatial = try? SpatialRenderer(sampleRate: newSession.sampleRate, parameters: params)
                    }
                    renderer.submitSpatial(spatial)
                }
                try newSession.startIO()
            } catch {
                newSession.invalidate()
                throw error
            }
            old?.invalidate()
            session = newSession
            if let chain, chain.sampleRate != newSession.sampleRate { buildChain() }
            else if chain == nil, !effectSlots.isEmpty { buildChain() }
            sessionGeneration += 1
            sessionStartNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            deviceListeners = [
                try? PropertyListener(object: deviceID, selector: kAudioDevicePropertyDataSource,
                                      scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                    MainActor.assumeIsolated {
                        if let device = try? AudioSystem.describe(deviceID) { self?.onOutputDeviceChange?(device) }
                    }
                },
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
            Self.log.info("Running on \(device.name) @ \(newSession.sampleRate) Hz with \(newSession.stripKeys.count) strips")
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
