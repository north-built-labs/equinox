import AVFoundation
import EquinoxAudio
import EquinoxDSP
import Foundation

/// End-to-end audio check: plays a 1 kHz tone through the system (afplay), captures it with the real
/// tap session, and measures Equinox's processed output at exactly 1 kHz (Goertzel), so other audio
/// playing at the same time does not disturb the readings.
@MainActor
final class SelfTest {
    private static let toneHz = 1000.0
    private static let toneDB = -30.0

    private let audio = AudioController()
    private let output: URL
    private var report: [String] = []
    private var failures = 0
    private var player: Process?
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

        do { try startTone(seconds: 26) } catch {
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

        audio.apply(DSPSettings())
        audio.restart()
        let recovered = await waitForRunning()
        await sleep(1.0)
        let after = await measure(DSPSettings())
        check("engine recovers after rebuild", recovered && abs(after - flat) < 1.5, "\(fmt(after)) dBFS")

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let age = Double(now &- audio.renderer.lastCallbackNanos()) / 1e9
        check("audio callback alive", age < 0.5, "last callback \(String(format: "%.3f", age)) s ago")

        while player?.isRunning == true { await sleep(0.2) }
        await sleep(1.0)
        let residual = await measure(DSPSettings())
        check("no feedback after playback stops", residual < -80, "1 kHz residual \(fmt(residual)) dBFS")

        finish()
    }

    /// Gives afplay (the tone) its own strip and checks per-app volume, mute, EQ and isolation from Other Apps.
    private func perAppChecks(flat: Double) async {
        let tone = AudioSystem.audioProcesses().filter { $0.executableName == "afplay" }.map(\.objectID)
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

    // MARK: Measurement

    /// Applies settings, lets the ramp settle, then returns the median 1 kHz level of five reads.
    private func measure(_ settings: DSPSettings) async -> Double {
        audio.apply(settings)
        await sleep(0.6)
        var readings: [Double] = []
        let n = Int(sampleRate / 10)   // exactly 100 cycles of 1 kHz
        var buffer = [Float](repeating: 0, count: n)
        for _ in 0..<5 {
            audio.analysis.copyLatest(into: &buffer)
            readings.append(Self.goertzelDB(buffer, frequency: Self.toneHz, sampleRate: sampleRate))
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

    private func startTone(seconds: Double) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-selftest-tone.wav")
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let amplitude = Float(Decibels.toLinear(Self.toneDB))
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = amplitude * Float(sin(2 * Double.pi * Self.toneHz * Double(i) / rate)) }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [url.path]
        try p.run()
        player = p
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
