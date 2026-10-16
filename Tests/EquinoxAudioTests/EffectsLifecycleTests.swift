import AVFoundation
import XCTest
@testable import EquinoxAudio
import EquinoxDSP

@MainActor
final class EffectsLifecycleTests: XCTestCase {
    func settle() async { try? await Task.sleep(for: .milliseconds(600)) }

    /// Add X, then remove it before X's build finishes: the in-flight build must not install X.
    func testInFlightBuildCannotResurrectRemovedEffect() async {
        let audio = AudioController()
        let a = EffectSlot(kind: .builtIn(.delay)), x = EffectSlot(kind: .builtIn(.reverb))
        audio.setEffects([a]); await settle()
        audio.setEffects([a, x])
        audio.setEffects([a])
        await settle()
        XCTAssertNotNil(audio.effectUnit(for: a.id))
        XCTAssertNil(audio.effectUnit(for: x.id))
    }

    /// A reload request rebuilds from the slots' stored state instead of carrying live parameters over.
    func testReloadAppliesStoredStateInsteadOfLiveState() async throws {
        let audio = AudioController()
        let slot = EffectSlot(kind: .builtIn(.limiter))
        audio.setEffects([slot]); await settle()
        let pre = audio.effectUnit(for: slot.id)!.parameterTree!.parameter(withAddress: 2)!
        pre.value = 6
        var saved = slot; saved.state = audio.captureEffectStates()[slot.id]
        pre.value = 12                                   // live tweak after saving
        audio.setEffects([saved], reload: true); await settle()
        XCTAssertEqual(audio.effectUnit(for: slot.id)!.parameterTree!.parameter(withAddress: 2)!.value, 6, accuracy: 0.01)
    }

    func testParameterChangesAreReported() async {
        let audio = AudioController()
        var changes = 0
        audio.onEffectParametersChanged = { changes += 1 }
        let slot = EffectSlot(kind: .builtIn(.limiter))
        audio.setEffects([slot]); await settle()
        XCTAssertEqual(changes, 0, "loading a chain is not a user edit")
        audio.effectUnit(for: slot.id)!.parameterTree!.parameter(withAddress: 2)!.value = 3
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(changes, 0)
    }

    func testChainChangesAreReported() async {
        let audio = AudioController()
        var changes = 0
        audio.onEffectsChainChanged = { changes += 1 }
        audio.setEffects([EffectSlot(kind: .builtIn(.delay))]); await settle()
        XCTAssertEqual(changes, 1)
    }

    /// Resetting the renderer (IO stopped) must drop a pending, never-taken chain on the main thread,
    /// not leave it for the audio thread to release.
    func testPrepareDropsPendingChainOnMainThread() async throws {
        let renderer = Renderer()
        weak var weakChain: EffectsChain?
        do {
            let chain = try await EffectsChain.make(slots: [EffectSlot(kind: .builtIn(.delay))], sampleRate: 48_000,
                                                    loader: EffectLoader(pluginGuard: nil))
            weakChain = chain
            renderer.submitEffects(chain)
        }
        renderer.prepare(sampleRate: 44_100, inputStreamOffset: 0, stripCount: 1)
        XCTAssertNil(weakChain)
    }
}

final class PluginGuardSetTests: XCTestCase {
    func testOverlappingLoadsKeepEachOthersMarkers() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-guard2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = AudioUnitID(type: 1, subType: 2, manufacturer: 3, name: "X", manufacturerName: "V")
        let y = AudioUnitID(type: 4, subType: 5, manufacturer: 6, name: "Y", manufacturerName: "V")
        let g = PluginGuard(directory: dir)
        g.begin(x); g.begin(x); g.begin(y)
        g.end(x)                                            // first build finishes
        XCTAssertEqual(Set(PluginGuard(directory: dir).takeCrashedPlugins()), [x, y])
        XCTAssertTrue(PluginGuard(directory: dir).takeCrashedPlugins().isEmpty)
    }
}
