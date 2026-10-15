import XCTest
@testable import EquinoxDSP

final class EffectsModelTests: XCTestCase {
    func testSlotRoundTripsThroughJSON() throws {
        let au = AudioUnitID(type: 0x61756678, subType: 0x62706173, manufacturer: 0x6170706C, name: "AUBandpass", manufacturerName: "Apple")
        let slots = [EffectSlot(kind: .builtIn(.reverb), isEnabled: false, state: Data([1, 2, 3])),
                     EffectSlot(kind: .audioUnit(au))]
        let decoded = try JSONDecoder().decode([EffectSlot].self, from: JSONEncoder().encode(slots))
        XCTAssertEqual(decoded, slots)
        XCTAssertEqual(decoded[1].kind.displayName, "AUBandpass")
        XCTAssertEqual(au.key, "61756678-62706173-6170706C")
    }

    func testStructureIgnoresState() {
        let a = EffectSlot(kind: .builtIn(.delay), state: Data([1]))
        var b = a; b.state = Data([2])
        XCTAssertEqual(a.structure, b.structure)
        b.isEnabled = false
        XCTAssertNotEqual(a.structure, b.structure)
    }

    func testPrePlusPostEqualsProcess() {
        var s = DSPSettings(); s.softwareVolume = 0.5
        s.bands = [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)]
        let a = MasterProcessor(maxFrames: 512, sampleRate: 48_000), b = MasterProcessor(maxFrames: 512, sampleRate: 48_000)
        a.apply(DSPConfig(settings: s, sampleRate: 48_000)); b.apply(DSPConfig(settings: s, sampleRate: 48_000))
        var l1 = Signal.sine(1000, fs: 48_000, count: 2000), r1 = l1, l2 = l1, r2 = l1
        l1.withUnsafeMutableBufferPointer { lp in r1.withUnsafeMutableBufferPointer { rp in
            a.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 2000) } }
        l2.withUnsafeMutableBufferPointer { lp in r2.withUnsafeMutableBufferPointer { rp in
            b.processPre(left: lp.baseAddress!, right: rp.baseAddress!, frames: 2000)
            b.processPost(left: lp.baseAddress!, right: rp.baseAddress!, frames: 2000) } }
        XCTAssertEqual(l1, l2)
    }

    func testPostSilencesNonFiniteFromEffects() {
        let p = MasterProcessor(maxFrames: 512, sampleRate: 48_000)
        p.apply(DSPConfig(settings: DSPSettings(), sampleRate: 48_000))
        var l = [Float](repeating: .infinity, count: 64), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            p.processPost(left: lp.baseAddress!, right: rp.baseAddress!, frames: 64) } }
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
    }
}
