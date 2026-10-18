import Accelerate
import Foundation

/// A compact acoustic fingerprint (Haitsma–Kalker): one 32-bit value per 11.6 ms that records
/// whether neighbouring frequency bands grow or shrink over time. Identical music produces the
/// same values even when the surrounding scenes differ. Fingerprints exist only in memory.
enum AudioFingerprint {
  static let sampleRate: Double = 11_025
  static let frameLength = 4_096
  static let hop = 128
  static var hopSeconds: Double { Double(hop) / sampleRate }

  private static let bandCount = 33
  private static let lowFrequency: Double = 300
  private static let highFrequency: Double = 2_000

  static func compute(_ samples: [Float]) -> [UInt32] {
    let frameCount = samples.count >= frameLength ? (samples.count - frameLength) / hop + 1 : 0
    guard frameCount > 1 else { return [] }
    let log2n = vDSP_Length(log2(Double(frameLength)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
    defer { vDSP_destroy_fftsetup(setup) }

    var window = [Float](repeating: 0, count: frameLength)
    vDSP_hann_window(&window, vDSP_Length(frameLength), Int32(vDSP_HANN_NORM))
    let edges = (0...bandCount).map { index -> Int in
      let frequency =
        lowFrequency * pow(highFrequency / lowFrequency, Double(index) / Double(bandCount))
      return Int((frequency * Double(frameLength) / sampleRate).rounded())
    }

    let half = frameLength / 2
    var frame = [Float](repeating: 0, count: frameLength)
    var real = [Float](repeating: 0, count: half)
    var imaginary = [Float](repeating: 0, count: half)
    var power = [Float](repeating: 0, count: half)
    var previous = [Float](repeating: 0, count: bandCount)
    var current = [Float](repeating: 0, count: bandCount)
    var result = [UInt32]()
    result.reserveCapacity(frameCount - 1)

    for frameIndex in 0..<frameCount {
      let start = frameIndex * hop
      samples.withUnsafeBufferPointer { buffer in
        vDSP_vmul(
          buffer.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(frameLength))
      }
      real.withUnsafeMutableBufferPointer { realBuffer in
        imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
          var split = DSPSplitComplex(
            realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
          frame.withUnsafeBufferPointer { frameBuffer in
            frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
              vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
            }
          }
          vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
          vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
        }
      }
      for band in 0..<bandCount {
        let low = max(edges[band], 1)
        let high = max(edges[band + 1], low + 1)
        var sum: Float = 0
        power.withUnsafeBufferPointer { buffer in
          vDSP_sve(buffer.baseAddress! + low, 1, &sum, vDSP_Length(high - low))
        }
        current[band] = sum
      }
      if frameIndex > 0 {
        var value: UInt32 = 0
        for bit in 0..<(bandCount - 1) {
          let difference =
            (current[bit] - current[bit + 1]) - (previous[bit] - previous[bit + 1])
          if difference > 0 { value |= 1 << UInt32(bit) }
        }
        result.append(value)
      }
      swap(&previous, &current)
    }
    return result
  }
}
