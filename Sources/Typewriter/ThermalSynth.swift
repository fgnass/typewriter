import AVFoundation

/// Synthetic sounds of an electronic thermal typewriter from the 1980s:
/// no hammer strike, but stepper motors that move the print head and feed the paper,
/// a soft tick of the thermal head, and an electronic beep near the margin.
enum ThermalSynth {
    private static let rate = 44100.0

    static func make(_ kind: SoundEngine.Kind, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        switch kind {
        case .key:
            return (0..<5).map { i in
                var s = mix(tick(seed: UInt64(10 + i), level: 0.35), at: 0,
                            with: step(seed: UInt64(20 + i), variation: Double(i)), offset: 0.012)
                normalize(&s, peak: 0.55)
                return buffer(s, format)
            }
        case .space:
            return (0..<3).map { i in
                var s = step(seed: UInt64(40 + i), variation: Double(i))
                normalize(&s, peak: 0.45)
                return buffer(s, format)
            }
        case .backspace:
            return (0..<2).map { i in
                var s = mix(step(seed: UInt64(60 + i), variation: Double(i) + 2), at: 0,
                            with: tick(seed: UInt64(70 + i), level: 0.25, bright: true), offset: 0.03)
                normalize(&s, peak: 0.45)
                return buffer(s, format)
            }
        case .carriageReturn:
            // A long glide back to the left margin, then the paper feed.
            let glide = stepper(duration: 0.34, startRate: 350, peakRate: 3000, endRate: 350,
                                ring: 2300, body: 260, seed: 90, whine: 0.08)
            var s = mix(glide, at: 0, with: lineFeed(seed: 91), offset: 0.33)
            normalize(&s, peak: 0.5)
            return [buffer(s, format)]
        case .feed:
            var s = lineFeed(seed: 95)
            normalize(&s, peak: 0.45)
            return [buffer(s, format)]
        case .bell:
            var s = beep()
            normalize(&s, peak: 0.22)
            return [buffer(s, format)]
        case .hum:
            return []
        }
    }

    // MARK: Building blocks

    /// One character step of the print head motor: a short, rising and falling buzz.
    private static func step(seed: UInt64, variation: Double) -> [Float] {
        stepper(duration: 0.03 + variation * 0.002, startRate: 700, peakRate: 1500 + variation * 40, endRate: 700,
                ring: 2400 + variation * 90, body: 320, seed: seed, whine: 0.05)
    }

    private static func lineFeed(seed: UInt64) -> [Float] {
        stepper(duration: 0.09, startRate: 300, peakRate: 820, endRate: 300, ring: 1500, body: 150, seed: seed, whine: 0.06)
    }

    /// A stepper motor: every step is a short metallic impulse. The step rate ramps up, holds, and ramps down,
    /// which gives the typical whirr whose pitch follows the speed.
    private static func stepper(duration: Double, startRate: Double, peakRate: Double, endRate: Double,
                                ring: Double, body: Double, seed: UInt64, whine: Double) -> [Float] {
        let tail = 0.03
        let n = Int((duration + tail) * rate)
        var out = [Double](repeating: 0, count: n)
        var rng = SplitMix64(seed: seed)
        // Step times from the rate profile.
        var steps: [Int] = []
        var phase = 0.0
        var whinePhase = 0.0
        for i in 0..<Int(duration * rate) {
            let t = Double(i) / rate / duration
            let r: Double
            if t < 0.35 { r = startRate + (peakRate - startRate) * smooth(t / 0.35) }
            else if t > 0.65 { r = peakRate + (endRate - peakRate) * smooth((t - 0.65) / 0.35) }
            else { r = peakRate }
            phase += r / rate
            if phase >= 1 { phase -= 1; steps.append(i) }
            whinePhase += r / rate
            let env = sin(.pi * t)
            out[i] += whine * env * (sin(2 * .pi * whinePhase) + 0.35 * sin(4 * .pi * whinePhase))
        }
        // Impulse response of one step.
        let hLen = Int(0.012 * rate)
        var h = [Double](repeating: 0, count: hLen)
        for i in 0..<hLen {
            let t = Double(i) / rate
            h[i] = exp(-t / 0.0016) * (0.55 * sin(2 * .pi * ring * t) + 0.3 * sin(2 * .pi * ring * 1.53 * t))
                + 0.35 * exp(-t / 0.005) * sin(2 * .pi * body * t)
        }
        for s in steps {
            let gain = 0.85 + 0.3 * rng.nextUnit()
            for i in 0..<hLen where s + i < n {
                out[s + i] += gain * (h[i] + 0.05 * (rng.nextUnit() * 2 - 1) * exp(-Double(i) / rate / 0.002))
            }
        }
        return out.map { Float($0) }
    }

    /// The thermal head touches the paper: a very short, soft tick.
    private static func tick(seed: UInt64, level: Double, bright: Bool = false) -> [Float] {
        let n = Int(0.02 * rate)
        var rng = SplitMix64(seed: seed)
        var lp = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let noise = rng.nextUnit() * 2 - 1
            lp += (noise - lp) * (bright ? 0.6 : 0.35)
            let click = (noise - lp) * exp(-t / 0.0015)
            let thud = sin(2 * .pi * 190 * t) * exp(-t / 0.006) * 0.6
            return Float(level * (click + thud))
        }
    }

    /// An electronic margin beep.
    private static func beep() -> [Float] {
        let n = Int(0.12 * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.004) * min(1, (0.12 - t) / 0.03)
            return Float(env * (sin(2 * .pi * 1760 * t) + 0.12 * sin(2 * .pi * 5280 * t)))
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
