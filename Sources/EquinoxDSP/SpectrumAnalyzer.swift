import Accelerate

/// FFT spectrum reduced to log-spaced bands in dBFS. Main-thread use; not realtime.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let frequencies: [Double]
    private let edges: [Double]
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]

    public init(fftSize: Int = 4096, bandCount: Int = 96, minFrequency: Double = 20, maxFrequency: Double = 20_000) {
        self.fftSize = fftSize
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        let ratio = maxFrequency / minFrequency
        let e = (0...bandCount).map { minFrequency * pow(ratio, Double($0) / Double(bandCount)) }
        edges = e
        frequencies = (0..<bandCount).map { sqrt(e[$0] * e[$0 + 1]) }
    }

    public func analyze(_ samples: [Float], sampleRate: Double) -> [Float] {
        precondition(samples.count == fftSize)
        vDSP.multiply(samples, window, result: &windowed)
        let half = fftSize / 2
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // vDSP real FFT is scaled by 2; with a Hann window a full-scale sine peaks at N/2.
        let norm = Float(half) * Float(half)
        let binHz = sampleRate / Double(fftSize)
        var result = [Float](repeating: -120, count: frequencies.count)
        for b in 0..<frequencies.count {
            var lo = Int((edges[b] / binHz).rounded(.down))
            var hi = Int((edges[b + 1] / binHz).rounded(.up))
            lo = min(max(lo, 1), half - 1); hi = min(max(hi, lo), half - 1)
            var p: Float = 0
            for k in lo...hi { p = max(p, power[k]) }
            result[b] = max(10 * log10(max(p / norm, 1e-12)), -120)
        }
        return result
    }
}
