import XCTest
@testable import EquinoxDSP

final class AnalysisTests: XCTestCase {
    func write(_ tap: AnalysisTap, _ l: [Float], _ r: [Float]) {
        var l = l, r = r
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            tap.write(left: lp.baseAddress!, right: rp.baseAddress!, frames: lp.count)
        } }
    }

    func testCopyLatestReturnsNewestMonoSamples() {
        let tap = AnalysisTap()
        let l = (0..<100).map { Float($0) }, r = l.map { $0 + 2 }
        write(tap, l, r)
        var out = [Float](repeating: 0, count: 10)
        tap.copyLatest(into: &out)
        XCTAssertEqual(out, (90..<100).map { Float($0) + 1 })
    }

    func testCopyLatestWrapsAroundRing() {
        let tap = AnalysisTap()
        let block = [Float](repeating: 0.25, count: 4000)
        for _ in 0..<5 { write(tap, block, block) }   // 20000 > capacity
        var out = [Float](repeating: 0, count: 4096)
        tap.copyLatest(into: &out)
        XCTAssertTrue(out.allSatisfy { $0 == 0.25 })
    }

    func testPeaksAreTakenAndReset() {
        let tap = AnalysisTap()
        write(tap, [0.1, -0.8, 0.2], [0.3, 0.05, -0.4])
        let p = tap.takePeaks()
        XCTAssertEqual(p.left, 0.8, accuracy: 1e-6); XCTAssertEqual(p.right, 0.4, accuracy: 1e-6)
        XCTAssertEqual(tap.takePeaks().left, 0)
    }

    func testSpectrumFindsSineAtZeroDB() {
        let fs = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let x = Signal.sine(1000, fs: fs, count: analyzer.fftSize, amplitude: 1)
        let bands = analyzer.analyze(x, sampleRate: fs)
        XCTAssertEqual(bands.count, analyzer.frequencies.count)
        let i1k = analyzer.frequencies.enumerated().min { abs($0.1 - 1000) < abs($1.1 - 1000) }!.offset
        let i10k = analyzer.frequencies.enumerated().min { abs($0.1 - 10000) < abs($1.1 - 10000) }!.offset
        XCTAssertEqual(Double(bands[i1k]), 0, accuracy: 2)
        XCTAssertLessThan(bands[i10k], -50)
    }
}
