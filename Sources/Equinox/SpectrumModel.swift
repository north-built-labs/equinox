import EquinoxDSP
import Observation
import SwiftUI

/// Polls the analysis tap at display rate while at least one view is attached.
@MainActor
@Observable
final class SpectrumModel {
    private(set) var levels: [Float]
    private(set) var peakLeft: Float = 0
    private(set) var peakRight: Float = 0
    private(set) var listening = ListeningActivity()
    let frequencies: [Double]

    @ObservationIgnored private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored private let tap: AnalysisTap
    @ObservationIgnored private let sampleRate: () -> Double
    @ObservationIgnored private var samples: [Float]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clients = 0
    @ObservationIgnored private var isFrozen = false

    init(tap: AnalysisTap, sampleRate: @escaping () -> Double) {
        self.tap = tap
        self.sampleRate = sampleRate
        frequencies = analyzer.frequencies
        levels = Array(repeating: -120, count: analyzer.frequencies.count)
        samples = Array(repeating: 0, count: analyzer.fftSize)
    }

    func attach() {
        clients += 1
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func detach() {
        clients = max(clients - 1, 0)
        if clients == 0 { timer?.invalidate(); timer = nil }
    }

    /// Diagnostics: show fixed levels and stop polling the tap.
    func freeze(levels: [Float], peakLeft: Float, peakRight: Float, listening: ListeningActivity = ListeningActivity()) {
        isFrozen = true
        self.levels = levels
        self.peakLeft = peakLeft
        self.peakRight = peakRight
        self.listening = listening
    }

    private func tick() {
        guard !isFrozen else { return }
        listening = tap.readListening()
        tap.copyLatest(into: &samples)
        let fresh = analyzer.analyze(samples, sampleRate: sampleRate())
        var next = levels
        for i in next.indices {
            let target = fresh[i]
            next[i] = target > next[i] ? next[i] + (target - next[i]) * 0.6 : next[i] + (target - next[i]) * 0.12
        }
        levels = next
        let p = tap.takePeaks()
        peakLeft = max(p.left, peakLeft * 0.88)
        peakRight = max(p.right, peakRight * 0.88)
    }
}
