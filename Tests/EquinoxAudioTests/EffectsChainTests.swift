import AVFoundation
import XCTest
@testable import EquinoxAudio
import EquinoxDSP

@MainActor
final class EffectsChainTests: XCTestCase {
    let fs = 48_000.0
    static let preGain: AUParameterAddress = 2   // AUPeakLimiter "Pre-Gain", −40…40 dB

    func sine(_ n: Int, amplitude: Float = 0.0316) -> [Float] {
        (0..<n).map { amplitude * Float(sin(2 * Double.pi * 1000 * Double($0) / fs)) }
    }

    /// Renders `blocks` × `size` frames of a 1 kHz sine; returns the output/input level in dB over the last half.
    func gainDB(_ chain: EffectsChain, blocks: Int = 24, size: Int = 512) -> Double {
        let x = sine(blocks * size)
        var y = x, yr = x
        y.withUnsafeMutableBufferPointer { l in yr.withUnsafeMutableBufferPointer { r in
            for b in 0..<blocks { chain.render(left: l.baseAddress! + b * size, right: r.baseAddress! + b * size, frames: size) }
        } }
        let half = x.count / 2
        let pin = x[half...].reduce(0) { $0 + $1 * $1 }, pout = y[half...].reduce(0) { $0 + $1 * $1 }
        return 10 * log10(Double(pout / pin))
    }

    func makeLimiter(state: Data? = nil, enabled: Bool = true) async throws -> (EffectsChain, UUID) {
        let slot = EffectSlot(kind: .builtIn(.limiter), isEnabled: enabled, state: state)
        let chain = try await EffectsChain.make(slots: [slot], sampleRate: fs, loader: EffectLoader(pluginGuard: nil))!
        return (chain, slot.id)
    }

    func testEmptyChainIsNil() async throws {
        let chain = try await EffectsChain.make(slots: [], sampleRate: fs, loader: EffectLoader(pluginGuard: nil))
        XCTAssertNil(chain)
    }

    func testChainAppliesUnitProcessing() async throws {
        let (chain, id) = try await makeLimiter()
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        XCTAssertEqual(gainDB(chain), 6, accuracy: 0.1)
    }

    func testBypassedSlotPassesThroughLive() async throws {
        let (chain, id) = try await makeLimiter()
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        chain.setBypassed(id, true)
        XCTAssertEqual(gainDB(chain), 0, accuracy: 0.05)
    }

    func testDisabledSlotStartsBypassed() async throws {
        let (chain, id) = try await makeLimiter(enabled: false)
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        XCTAssertEqual(gainDB(chain), 0, accuracy: 0.05)
    }

    func testStateRoundTripsThroughFullState() async throws {
        let (a, id) = try await makeLimiter()
        a.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        let state = a.captureStates()[id]
        XCTAssertNotNil(state)
        let (b, _) = try await makeLimiter(state: state)
        XCTAssertEqual(gainDB(b), 6, accuracy: 0.1)
    }

    func testChunksLargeBuffers() async throws {
        let (chain, id) = try await makeLimiter()
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        XCTAssertEqual(gainDB(chain, blocks: 3, size: 10_000), 6, accuracy: 0.1)
    }

    func testChainBuiltAtRequestedRate() async throws {
        let slot = EffectSlot(kind: .builtIn(.delay))
        let chain = try await EffectsChain.make(slots: [slot], sampleRate: 96_000, loader: EffectLoader(pluginGuard: nil))!
        XCTAssertEqual(chain.sampleRate, 96_000)
    }

    func testAllBuiltInsLoad() async throws {
        let slots = BuiltInEffect.allCases.map { EffectSlot(kind: .builtIn($0)) }
        let chain = try await EffectsChain.make(slots: slots, sampleRate: fs, loader: EffectLoader(pluginGuard: nil))!
        XCTAssertEqual(chain.slots.count, BuiltInEffect.allCases.count)
        for s in slots { XCTAssertNotNil(chain.unit(for: s.id)) }
    }

    func testInstalledAudioUnitLoadsThroughPluginPath() async throws {
        let catalog = PluginCatalog.installedEffects()
        let bandpass = try XCTUnwrap(catalog.first { $0.name.contains("AUBandpass") })
        let slot = EffectSlot(kind: .audioUnit(bandpass))
        let chain = try await EffectsChain.make(slots: [slot], sampleRate: fs, loader: EffectLoader(pluginGuard: nil))!
        XCTAssertLessThan(gainDB(chain), -6)   // default 5 kHz band-pass attenuates 1 kHz
    }

    func testUnloadableSlotIsSkipped() async throws {
        let bogus = AudioUnitID(type: 0x61756678, subType: 0x7A7A7A7A, manufacturer: 0x7A7A7A7A, name: "Nope", manufacturerName: "None")
        let good = EffectSlot(kind: .builtIn(.delay))
        let chain = try await EffectsChain.make(slots: [EffectSlot(kind: .audioUnit(bogus)), good], sampleRate: fs,
                                                loader: EffectLoader(pluginGuard: nil))!
        XCTAssertEqual(chain.slots.map(\.id), [good.id])
    }

    func testRendererAppliesEffectsBetweenEQAndOutput() async throws {
        let (chain, id) = try await makeLimiter()
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        let renderer = Renderer()
        renderer.prepare(sampleRate: fs, inputStreamOffset: 0, stripCount: 1)
        renderer.submit(DSPConfig(settings: DSPSettings(), sampleRate: fs))
        renderer.submitEffects(chain)
        let frames = 512
        let x = sine(frames * 24)
        var outLevel: Double = 0, inLevel: Double = 0
        for b in 0..<24 {
            let input = AudioBufferList.allocate(maximumBuffers: 1)
            let ip = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            for i in 0..<frames { ip[2 * i] = x[b * frames + i]; ip[2 * i + 1] = x[b * frames + i] }
            input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: ip)
            let output = AudioBufferList.allocate(maximumBuffers: 1)
            let op = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: op)
            renderer.render(input: UnsafePointer(input.unsafeMutablePointer), output: output.unsafeMutablePointer)
            if b >= 12 { for i in 0..<frames { inLevel += Double(ip[2 * i] * ip[2 * i]); outLevel += Double(op[2 * i] * op[2 * i]) } }
        }
        XCTAssertEqual(10 * log10(outLevel / inLevel), 6, accuracy: 0.1)
    }
}

final class PluginGuardTests: XCTestCase {
    func testMarkerLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = AudioUnitID(type: 1, subType: 2, manufacturer: 3, name: "Crashy", manufacturerName: "X")
        let guardFile = PluginGuard(directory: dir)
        XCTAssertTrue(guardFile.takeCrashedPlugins().isEmpty)
        guardFile.begin(id)
        guardFile.end(id)
        XCTAssertTrue(guardFile.takeCrashedPlugins().isEmpty)
        guardFile.begin(id)                       // "crash" before end()
        XCTAssertEqual(PluginGuard(directory: dir).takeCrashedPlugins(), [id])
        XCTAssertTrue(PluginGuard(directory: dir).takeCrashedPlugins().isEmpty)   // consumed
    }
}
