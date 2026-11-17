import AVFoundation

/// Synthetic sounds for the electronic typewriter. The goal is a warm, calm feeling:
/// everything is soft and low, like a well-damped device with felt and rubber inside,
/// not a mechanical clatter and not a bright electronic whine. Most energy sits between 200 and 800 Hz: warm, but still audible on laptop speakers.
enum ThermalSynth {
    private static let rate = 44100.0

    static func make(_ kind: SoundEngine.Kind, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        switch kind {
        case .key:
            return (0..<5).map { i in
                var s = mix(tap(seed: UInt64(10 + i), pitch: 1 + Double(i) * 0.03), at: 0,
                            with: purr(duration: 0.05, seed: UInt64(20 + i), level: 0.35), offset: 0.01)
                normalize(&s, peak: 0.42)
                return buffer(s, format)
            }
        case .space:
            return (0..<3).map { i in
                var s = purr(duration: 0.07, seed: UInt64(40 + i), level: 1)
                normalize(&s, peak: 0.26)
                return buffer(s, format)
            }
        case .backspace:
            return (0..<2).map { i in
                var s = mix(purr(duration: 0.06, seed: UInt64(60 + i), level: 1), at: 0,
                            with: tap(seed: UInt64(70 + i), pitch: 1.15), offset: 0.03)
                normalize(&s, peak: 0.3)
                return buffer(s, format)
            }
        case .carriageReturn:
            var s = mix(glide(duration: 0.4, seed: 90), at: 0, with: settle(seed: 91), offset: 0.36)
            normalize(&s, peak: 0.4)
            return [buffer(s, format)]
        case .feed:
            var s = purr(duration: 0.14, seed: 95, level: 1, low: true)
            normalize(&s, peak: 0.3)
            return [buffer(s, format)]
        case .bell:
            var s = chime()
            normalize(&s, peak: 0.16)
            return [buffer(s, format)]
        case .hum:
            return []
        }
    }

    // MARK: Building blocks

    /// A soft, low key tap: a damped body thump with a very muffled contact.
    private static func tap(seed: UInt64, pitch: Double) -> [Float] {
        let n = Int(0.06 * rate)
        var rng = SplitMix64(seed: seed)
        var lp1 = 0.0, lp2 = 0.0
        let body = 260 * pitch
        return (0..<n).map { i in
            let t = Double(i) / rate
            let noise = rng.nextUnit() * 2 - 1
            // Two low-pass stages keep the contact soft (corner around 1 kHz).
            lp1 += (noise - lp1) * 0.17
            lp2 += (lp1 - lp2) * 0.17
            let contact = lp2 * exp(-t / 0.005) * 3.2
            let thump = sin(2 * .pi * body * t) * exp(-t / 0.016) + 0.45 * sin(2 * .pi * body * 2.1 * t) * exp(-t / 0.008)
            let attack = min(1, t / 0.0015)
            return Float(attack * (thump + contact))
        }
    }

    /// The motor moves the head: a quiet, low purr with a soft rise and fall.
    private static func purr(duration: Double, seed: UInt64, level: Double, low: Bool = false) -> [Float] {
        let n = Int((duration + 0.02) * rate)
        var rng = SplitMix64(seed: seed)
        var lp1 = 0.0, lp2 = 0.0
        var phase = 0.0
        let base = low ? 150.0 : 210.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let x = min(1, t / duration)
            let env = sin(.pi * x) * sin(.pi * x)
            let f = base * (1 + 0.6 * sin(.pi * x))
            phase += f / rate
            let tone = sin(2 * .pi * phase) + 0.3 * sin(4 * .pi * phase) + 0.1 * sin(6 * .pi * phase)
            let noise = rng.nextUnit() * 2 - 1
            lp1 += (noise - lp1) * 0.09
            lp2 += (lp1 - lp2) * 0.09
            return Float(level * env * (0.55 * tone + 2.5 * lp2))
        }
    }

    /// Carriage return: a calm, low glide, like a damped breath of air moving left.
    private static func glide(duration: Double, seed: UInt64) -> [Float] {
        let n = Int(duration * rate)
        var rng = SplitMix64(seed: seed)
        var lp1 = 0.0, lp2 = 0.0
        var phase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let x = t / duration
            let env = pow(sin(.pi * x), 1.5)
            // The low-pass opens a little in the middle, as the speed rises.
            let k = 0.04 + 0.05 * sin(.pi * x)
            let noise = rng.nextUnit() * 2 - 1
            lp1 += (noise - lp1) * k
            lp2 += (lp1 - lp2) * k
            phase += (170 + 110 * sin(.pi * x)) / rate
            return Float(env * (2.4 * lp2 + 0.3 * sin(2 * .pi * phase) + 0.1 * sin(4 * .pi * phase)))
        }
    }

    /// The head comes to rest at the margin: a soft, felted stop.
    private static func settle(seed: UInt64) -> [Float] {
        let n = Int(0.12 * rate)
        var rng = SplitMix64(seed: seed)
        var lp = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let noise = rng.nextUnit() * 2 - 1
            lp += (noise - lp) * 0.14
            return Float(min(1, t / 0.002) * (sin(2 * .pi * 230 * t) * exp(-t / 0.03) + 1.5 * lp * exp(-t / 0.006)))
        }
    }

    /// A warm, quiet margin chime: two low partials with a soft attack, like a small felt-struck gong.
    private static func chime() -> [Float] {
        let n = Int(0.7 * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.012) * exp(-t / 0.22)
            return Float(env * (sin(2 * .pi * 523.25 * t) + 0.35 * sin(2 * .pi * 784 * t) * exp(-t / 0.12)
                                + 0.12 * sin(2 * .pi * 1046.5 * t) * exp(-t / 0.06)))
        }
    }

    // MARK: Helpers

    private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private static func mix(_ a: [Float], at offsetA: Double, with b: [Float], offset: Double) -> [Float] {
        let ia = Int(offsetA * rate), ib = Int(offset * rate)
        var out = [Float](repeating: 0, count: max(ia + a.count, ib + b.count))
        for (i, v) in a.enumerated() { out[ia + i] += v }
        for (i, v) in b.enumerated() { out[ib + i] += v }
        return out
    }

    private static func normalize(_ s: inout [Float], peak: Float) {
        let m = s.map(abs).max() ?? 0
        guard m > 0 else { return }
        s = s.map { $0 / m * peak }
    }

    private static func buffer(_ s: [Float], _ format: AVAudioFormat) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count))!
        b.frameLength = AVAudioFrameCount(s.count)
        for ch in 0..<Int(format.channelCount) {
            s.withUnsafeBufferPointer { src in
                b.floatChannelData![ch].update(from: src.baseAddress!, count: s.count)
            }
        }
        return b
    }
}
