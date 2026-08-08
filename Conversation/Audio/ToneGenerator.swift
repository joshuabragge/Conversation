import Foundation

/// Generates a short mono 16-bit PCM WAV tone in memory. Used by
/// `AudioCueService` so earcons don't depend on bundled audio assets or on
/// undocumented system-sound IDs.
enum ToneGenerator {
    static func wavData(frequency: Double, duration: Double, sampleRate: Double = 44100) -> Data {
        let sampleCount = Int(sampleRate * duration)
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        let fadeSamples = max(1, Int(sampleRate * 0.01)) // 10ms fade in/out, avoids clicks
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let fade = min(1, Double(min(i, sampleCount - i)) / Double(fadeSamples))
            let value = sin(2 * .pi * frequency * t) * fade * 0.8
            samples.append(Int16(value * Double(Int16.max)))
        }

        var data = Data()
        let byteRate = Int32(sampleRate) * 2
        let dataSize = Int32(samples.count * 2)
        let chunkSize = 36 + dataSize

        func appendInt32(_ value: Int32) {
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
        }
        func appendInt16(_ value: Int16) {
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendInt32(chunkSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendInt32(16)          // fmt chunk size
        appendInt16(1)           // PCM
        appendInt16(1)           // mono
        appendInt32(Int32(sampleRate))
        appendInt32(byteRate)
        appendInt16(2)           // block align (16-bit mono)
        appendInt16(16)          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendInt32(dataSize)
        for sample in samples { appendInt16(sample) }
        return data
    }
}
