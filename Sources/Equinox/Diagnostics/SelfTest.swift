import AVFoundation
import EquinoxAudio
import EquinoxDSP
import Foundation

/// End-to-end audio check: plays a 1 kHz tone through the system (afplay), captures it with the real
/// tap session, and measures Equinox's processed output at exactly 1 kHz (Goertzel), so other audio
/// playing at the same time does not disturb the readings.
@MainActor
final class SelfTest {
    nonisolated private static let toneHz = 1000.0
    private static let toneDB = -30.0

    private let audio = AudioController()
    private let output: URL
    private var report: [String] = []
    private var failures = 0
    private var player: Process?
    private var player2: Process?
    private var sampleRate = 48_000.0

    private init(output: URL) { self.output = output }

    static func launch(output: URL) -> Never {
        MainActor.assumeIsolated {
            let test = SelfTest(output: output)
            Task { await test.run() }
        }
        dispatchMain()
    }

    private func run() async {
        audio.start()
        guard await waitForRunning() else {
            check("engine starts", false, "status: \(audio.status)")
            finish()
        }
        if case .running(let name, let rate) = audio.status {
            sampleRate = rate
            check("engine starts", true, "\(name) @ \(Int(rate)) Hz")
        }

        do { player = try startTone(frequency: Self.toneHz, seconds: 60, name: "tone1") } catch {
            check("test tone plays", false, "\(error)")
            finish()
        }
        await sleep(1.5)

        let flat = await measure(DSPSettings())
        check("tap captures system audio", flat > -45, "1 kHz tone measured at \(fmt(flat)) dBFS")
        check("flat EQ is transparent", abs(flat - Self.toneDB) < 1.5, "\(fmt(flat)) vs \(fmt(Self.toneDB)) sent")

        var peak = DSPSettings()
        peak.bands = [EQBand(type: .peak, frequency: 1000, gainDB: 12, q: 1)]
        let boosted = await measure(peak)
        check("+12 dB peak at 1 kHz", abs(boosted - flat - 12) < 1, "Δ \(fmt(boosted - flat)) dB")

        var shelf = DSPSettings()
        shelf.bands = [EQBand(type: .lowShelf, frequency: 100, gainDB: 12, q: 0.7)]
        let shelved = await measure(shelf)
        check("bass shelf leaves 1 kHz alone", abs(shelved - flat) < 1, "Δ \(fmt(shelved - flat)) dB")

        var bypass = peak
        bypass.isBypassed = true
        let bypassed = await measure(bypass)
        check("bypass is unprocessed", abs(bypassed - flat) < 0.5, "Δ \(fmt(bypassed - flat)) dB")

        var half = DSPSettings()
        half.softwareVolume = 0.5
        let halved = await measure(half)
        check("software volume 50% = −6 dB", abs(halved - flat + 6.02) < 0.5, "Δ \(fmt(halved - flat)) dB")

        var muted = DSPSettings()
        muted.isMuted = true
        let silent = await measure(muted)
        check("mute silences output", silent < -90, "\(fmt(silent)) dBFS")

        var extreme = DSPSettings()
        extreme.boostDB = 12; extreme.preampDB = 24
        extreme.bands = [EQBand(type: .peak, frequency: 1000, gainDB: 24, q: 1)]
        audio.apply(extreme)
        await sleep(0.6)
        _ = audio.analysis.takePeaks()
        await sleep(0.8)
        let peaks = audio.analysis.takePeaks()
        let ceiling = Float(Decibels.toLinear(-0.3)) + 1e-4
        check("limiter holds −0.3 dBFS ceiling", max(peaks.left, peaks.right) <= ceiling,
              "peak \(fmt(Decibels.fromLinear(Double(max(peaks.left, peaks.right))))) dBFS")

        await perAppChecks(flat: flat)
        await multiStripChecks(flat1: flat)
        await effectsChecks(flat: flat)

        audio.apply(DSPSettings())
        audio.restart()
        let recovered = await waitForRunning()
        await sleep(1.0)
        let after = await measure(DSPSettings())
        check("engine recovers after rebuild", recovered && abs(after - flat) < 1.5, "\(fmt(after)) dBFS")

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let age = Double(now &- audio.renderer.lastCallbackNanos()) / 1e9
        check("audio callback alive", age < 0.5, "last callback \(String(format: "%.3f", age)) s ago")

        while player?.isRunning == true || player2?.isRunning == true { await sleep(0.2) }
        await sleep(1.0)
        let residual = await measure(DSPSettings())
        check("no feedback after playback stops", residual < -80, "1 kHz residual \(fmt(residual)) dBFS")

        finish()
    }

    /// Gives afplay (the tone) its own strip and checks per-app volume, mute, EQ and isolation from Other Apps.
    private func perAppChecks(flat: Double) async {
        let tone = processObjects(of: player)
        guard !tone.isEmpty else { check("per-app: tone process found", false, "afplay not in HAL process list"); return }
        let key = "exe:afplay"
        audio.setDedicatedStrips([DedicatedStrip(key: key, processes: tone)])
        await sleep(0.6)   // debounced rebuild
        let rebuilt = await waitForRunning()
        await sleep(0.8)
        check("per-app: dedicated tap session", rebuilt && audio.activeStripKeys == ["", key],
              "strips \(audio.activeStripKeys)")

        var s = DSPSettings()
        s.strips = [StripSettings(key: key, volume: 0.5)]
        let half = await measure(s)
        check("per-app: app volume 50% = −6 dB", abs(half - flat + 6.02) < 0.5, "Δ \(fmt(half - flat)) dB")

        s.strips = [StripSettings(key: key, volume: 1), StripSettings(key: StripSettings.othersKey, volume: 0)]
        let isolated = await measure(s)
        check("per-app: Other Apps fader doesn't touch a dedicated app", abs(isolated - flat) < 0.5, "Δ \(fmt(isolated - flat)) dB")

        s.strips = [StripSettings(key: key, isMuted: true)]
        let muted = await measure(s)
        check("per-app: app mute", muted < -90, "\(fmt(muted)) dBFS")

        s.strips = [StripSettings(key: key, bands: [EQBand(type: .peak, frequency: 1000, gainDB: 12, q: 1)])]
        let eq = await measure(s)
        check("per-app: app EQ +12 dB at 1 kHz", abs(eq - flat - 12) < 1, "Δ \(fmt(eq - flat)) dB")

        audio.setDedicatedStrips([])
        await sleep(0.6)
        _ = await waitForRunning()
        await sleep(0.8)
    }

    /// Built-in limiter (+6 dB pre-gain) in the live chain, live bypass without rebuild, an installed Audio Unit
    /// through the plugin path, and removal.
    private func effectsChecks(flat: Double) async {
        var limiter = EffectSlot(kind: .builtIn(.limiter))
        audio.setEffects([limiter])
        await sleep(0.8)
        guard let unit = audio.effectUnit(for: limiter.id) else { check("effects: limiter loads", false, "no unit"); return }
        unit.parameterTree?.parameter(withAddress: 2)?.value = 6
        let boosted = await measure(DSPSettings())
        check("effects: limiter +6 dB pre-gain in live chain", abs(boosted - flat - 6) < 0.5, "Δ \(fmt(boosted - flat)) dB")

        limiter.isEnabled = false
        audio.setEffects([limiter])
        let bypassed = await measure(DSPSettings())
        check("effects: live bypass (same engine)", abs(bypassed - flat) < 0.5 && audio.effectUnit(for: limiter.id) === unit,
              "Δ \(fmt(bypassed - flat)) dB")

        var masterOff = DSPSettings(); masterOff.isBypassed = true
        limiter.isEnabled = true
        audio.setEffects([limiter])
        let off = await measure(masterOff)
        check("effects: Equinox off skips effects", abs(off - flat) < 0.5, "Δ \(fmt(off - flat)) dB")

        if let bandpass = PluginCatalog.installedEffects().first(where: { $0.name.contains("AUBandpass") }) {
            audio.setEffects([EffectSlot(kind: .audioUnit(bandpass))])
            await sleep(0.8)
            let filtered = await measure(DSPSettings())
            check("effects: installed Audio Unit (AUBandpass) runs", filtered < flat - 6, "Δ \(fmt(filtered - flat)) dB")
        }

        // Rapid structural edits: only the newest chain may win.
        for kind in [BuiltInEffect.reverb, .delay, .compressor] { audio.setEffects([EffectSlot(kind: .builtIn(kind))]) }
        audio.setEffects([])
        await sleep(1.0)
        let cleared = await measure(DSPSettings())
        check("effects: rapid edits converge to the last (none)", abs(cleared - flat) < 0.5, "Δ \(fmt(cleared - flat)) dB")
    }

    // MARK: Measurement

    /// Applies settings, lets the ramp settle, then returns the median 1 kHz level of five reads.
    private func measure(_ settings: DSPSettings, frequency: Double = SelfTest.toneHz) async -> Double {
        audio.apply(settings)
        await sleep(0.6)
        var readings: [Double] = []
        let n = Int(sampleRate / 10)   // exactly 100 cycles of 1 kHz
        var buffer = [Float](repeating: 0, count: n)
        for _ in 0..<5 {
            audio.analysis.copyLatest(into: &buffer)
            readings.append(Self.goertzelDB(buffer, frequency: frequency, sampleRate: sampleRate))
            await sleep(0.05)
        }
        return readings.sorted()[2]
    }

    static func goertzelDB(_ x: [Float], frequency: Double, sampleRate: Double) -> Double {
        let coeff = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = Double(v) + coeff * s1 - s2
            s2 = s1; s1 = s0
        }
        let power = max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0)
        return 20 * log10(max(2 * sqrt(power) / Double(x.count), 1e-9))
    }

    // MARK: Tone

    private func startTone(frequency: Double, seconds: Double, name: String) throws -> Process {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-selftest-\(name).wav")
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let amplitude = Float(Decibels.toLinear(Self.toneDB))
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / rate)) }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [url.path]
        try p.run()
        return p
    }

    private func processObjects(of process: Process?) -> [AudioObjectID] {
        guard let pid = process?.processIdentifier else { return [] }
        return AudioSystem.audioProcesses().filter { $0.pid == pid }.map(\.objectID)
    }

    private func applyStrips(_ strips: [DedicatedStrip]) async -> Bool {
        audio.setDedicatedStrips(strips)
        await sleep(0.6)   // debounced rebuild (if any)
        let ok = await waitForRunning()
        await sleep(0.8)
        return ok
    }

    /// Second tone (2.5 kHz, separate afplay process): checks strip order with 3 strips, tolerance of a dead
    /// process in a strip, and in-place process retargeting without a session rebuild.
    private func multiStripChecks(flat1: Double) async {
        let tone2Hz = 2500.0
        do { player2 = try startTone(frequency: tone2Hz, seconds: 22, name: "tone2") } catch {
            check("multi: second tone plays", false, "\(error)"); return
        }
        await sleep(1.2)
        let p1 = processObjects(of: player), p2 = processObjects(of: player2)
        let flat2 = await measure(DSPSettings(), frequency: tone2Hz)
        check("multi: second tone captured", flat2 > -45 && !p2.isEmpty, "2.5 kHz at \(fmt(flat2)) dBFS")

        // A strip whose process is gone must not take the session down.
        let ghost = await applyStrips([DedicatedStrip(key: "ghost", processes: [999_999]), DedicatedStrip(key: "t1", processes: p1)])
        check("multi: dead process in a strip is tolerated", ghost && Set(audio.activeStripKeys) == ["", "t1"],
              "strips \(audio.activeStripKeys)")

        // In-place: same keys, more processes → no rebuild, tone 2 moves into strip t1.
        _ = await applyStrips([DedicatedStrip(key: "t1", processes: p1)])
        let generation = audio.sessionGeneration
        _ = await applyStrips([DedicatedStrip(key: "t1", processes: (p1 + p2).sorted())])
        var s = DSPSettings()
        s.strips = [StripSettings(key: "t1", volume: 0.5)]
        let moved1 = await measure(s), moved2 = await measure(s, frequency: tone2Hz)
        check("multi: helper processes retargeted in place (no rebuild)",
              audio.sessionGeneration == generation && abs(moved1 - flat1 + 6.02) < 0.6 && abs(moved2 - flat2 + 6.02) < 0.6,
              "rebuilds \(audio.sessionGeneration - generation), Δ1 \(fmt(moved1 - flat1)), Δ2 \(fmt(moved2 - flat2))")

        // Three strips (Other Apps + 2 apps): each volume lands on the right app, both ways round.
        let three = await applyStrips([DedicatedStrip(key: "t1", processes: p1), DedicatedStrip(key: "t2", processes: p2)])
        s.strips = [StripSettings(key: "t1", volume: 0.5), StripSettings(key: "t2", volume: 0.25)]
        let a1 = await measure(s), a2 = await measure(s, frequency: tone2Hz)
        s.strips = [StripSettings(key: "t1", volume: 0.25), StripSettings(key: "t2", volume: 0.5)]
        let b1 = await measure(s), b2 = await measure(s, frequency: tone2Hz)
        let ok = three && abs(a1 - flat1 + 6.02) < 0.6 && abs(a2 - flat2 + 12.04) < 0.6
            && abs(b1 - flat1 + 12.04) < 0.6 && abs(b2 - flat2 + 6.02) < 0.6
        check("multi: 3 strips map to the right apps", ok,
              "\(audio.activeStripKeys): Δ \(fmt(a1 - flat1))/\(fmt(a2 - flat2)), swapped \(fmt(b1 - flat1))/\(fmt(b2 - flat2))")

        _ = await applyStrips([])
    }

    // MARK: Helpers

    private func waitForRunning() async -> Bool {
        for _ in 0..<60 {
            if audio.status.isRunning { return true }
            await sleep(0.1)
        }
        return audio.status.isRunning
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func fmt(_ v: Double) -> String { String(format: "%+.2f", v) }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        report.append("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
        if !ok { failures += 1 }
    }

    private func finish() -> Never {
        player?.terminate()
        audio.stop()
        report.append(failures == 0 ? "RESULT: all \(report.count) checks passed" : "RESULT: \(failures) of \(report.count) checks FAILED")
        let text = report.joined(separator: "\n") + "\n"
        try? text.write(to: output, atomically: true, encoding: .utf8)
        print(text, terminator: "")
        exit(failures == 0 ? 0 : 1)
    }
}
