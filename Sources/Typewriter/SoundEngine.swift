import AVFoundation

/// Plays typewriter sounds with small random variations, so repeated strikes do not sound identical.
final class SoundEngine {
    enum Kind: String, CaseIterable {
        case key, space, carriageReturn = "return", bell, backspace, feed, hum
    }

    enum Style: String, CaseIterable {
        case thermal, electric
        var title: String { self == .thermal ? "Thermal (1980s electronic)" : "Electric (recorded)" }
    }

    /// The sound style. Changing it reloads the sounds.
    var style: Style {
        get { Style(rawValue: UserDefaults.standard.string(forKey: "soundStyle") ?? "") ?? .thermal }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "soundStyle")
            loadSamples()
        }
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var voices: [(player: AVAudioPlayerNode, speed: AVAudioUnitVarispeed)] = []
    private var nextVoice = 0
    private var buffers: [Kind: [AVAudioPCMBuffer]] = [:]
    private var lastVariant: [Kind: Int] = [:]
    private var volumeScale: [Kind: Float] = [:]
    private let humPlayer = AVAudioPlayerNode()

    init() {
        for _ in 0..<12 {
            let p = AVAudioPlayerNode()
            let v = AVAudioUnitVarispeed()
            engine.attach(p)
            engine.attach(v)
            engine.connect(p, to: v, format: format)
            engine.connect(v, to: engine.mainMixerNode, format: format)
            voices.append((p, v))
        }
        engine.attach(humPlayer)
        engine.connect(humPlayer, to: engine.mainMixerNode, format: format)
        loadSamples()
        engine.prepare()
    }

    /// Debug aid: writes every loaded sound as a WAV file into the directory.
    func export(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (kind, list) in buffers {
            for (i, b) in list.enumerated() {
                let url = dir.appendingPathComponent("\(kind.rawValue)\(i + 1).wav")
                if let f = try? AVAudioFile(forWriting: url, settings: b.format.settings) { try? f.write(from: b) }
            }
        }
    }

    func start() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    func stop() {
        engine.stop()
    }

    var humEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "humEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "humEnabled") }
    }

    var hasHum: Bool { !(buffers[.hum] ?? []).isEmpty }

    /// The quiet motor hum of an electric typewriter, looped while the page is open.
    func startHum() {
        guard enabled, humEnabled, let hum = buffers[.hum]?.first else { return }
        start()
        humPlayer.stop()
        humPlayer.volume = 0.35
        humPlayer.scheduleBuffer(hum, at: nil, options: .loops)
        humPlayer.play()
    }

    func stopHum() {
        humPlayer.stop()
    }

    func play(_ kind: Kind, volume: Float = 1) {
        guard enabled, let list = buffers[kind], !list.isEmpty else { return }
        start()
        var idx = Int.random(in: 0..<list.count)
        if list.count > 1, idx == lastVariant[kind] { idx = (idx + 1) % list.count }
        lastVariant[kind] = idx
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.player.stop()
        let pitchy = kind == .key || kind == .space || kind == .backspace
        // Motors keep their pitch; only recorded strikes vary more.
        let spread: Float = style == .thermal ? 0.015 : 0.04
        voice.speed.rate = pitchy ? Float.random(in: (1 - spread)...(1 + spread)) : Float.random(in: 0.99...1.01)
        voice.player.volume = volume * (volumeScale[kind] ?? 1) * (pitchy ? Float.random(in: 0.75...1.0) : 1)
        voice.player.scheduleBuffer(list[idx], at: nil)
        voice.player.play()
    }

    // MARK: Loading

    private func loadSamples() {
        buffers = [:]
        volumeScale = [:]
        lastVariant = [:]
        if style == .thermal {
            for kind in Kind.allCases { buffers[kind] = ThermalSynth.make(kind, format: format) }
            return
        }
        let dir = Bundle.main.resourceURL?.appendingPathComponent("Sounds")
        let files = (dir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }) ?? []
        for kind in Kind.allCases {
            let matching = files.filter {
                let name = $0.deletingPathExtension().lastPathComponent.lowercased()
                return ["wav", "caf", "aif", "aiff", "mp3", "m4a"].contains($0.pathExtension.lowercased())
                    && (name == kind.rawValue || (name.hasPrefix(kind.rawValue) && Int(name.dropFirst(kind.rawValue.count)) != nil))
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var loaded = matching.compactMap(load)
            // Some recordings start with key travel noise before the strike. Start right at the strike,
            // so the sound feels immediate.
            if kind == .key || kind == .space || kind == .backspace { loaded = loaded.compactMap(trimToOnset) }
            buffers[kind] = loaded
        }
        let hasSamples = !(buffers[.key] ?? []).isEmpty
        if hasSamples {
            // No recordings exist for these. A soft strike sounds better than a synthetic sound next to real samples.
            if buffers[.backspace]?.isEmpty ?? true { buffers[.backspace] = buffers[.key] }
            volumeScale[.backspace] = 0.55
        }
        for kind in Kind.allCases where buffers[kind]?.isEmpty ?? true {
            buffers[kind] = (hasSamples && kind == .feed) || kind == .hum ? [] : Synth.make(kind, format: format)
        }
    }

    /// Removes everything before the first sample that reaches 30 % of the peak, minus 2 ms.
    private func trimToOnset(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let data = b.floatChannelData?[0] else { return b }
        let n = Int(b.frameLength)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(data[i])) }
        guard peak > 0 else { return b }
        var onset = 0
        while onset < n, abs(data[onset]) < peak * 0.3 { onset += 1 }
        let start = max(0, onset - Int(0.002 * b.format.sampleRate))
        return trim(b, seconds: Double(start) / b.format.sampleRate)
    }

    private func trim(_ b: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer? {
        let skip = AVAudioFrameCount(seconds * b.format.sampleRate)
        guard skip > 0 else { return b }
        guard b.frameLength > skip, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength - skip) else { return b }
        out.frameLength = b.frameLength - skip
        for ch in 0..<Int(b.format.channelCount) {
            memcpy(out.floatChannelData![ch], b.floatChannelData![ch] + Int(skip), Int(out.frameLength) * MemoryLayout<Float>.size)
        }
        return out
    }

    private func load(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: src)) != nil else { return nil }
        if src.format == format { return src }
        guard let conv = AVAudioConverter(from: src.format, to: format) else { return nil }
        let ratio = format.sampleRate / src.format.sampleRate
        guard let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: dst, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return err == nil ? dst : nil
    }
}

/// Simple procedural fallback sounds, used when no samples are bundled.
enum Synth {
    static func make(_ kind: SoundEngine.Kind, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        switch kind {
        case .key: return (0..<5).map { strike(format, seed: UInt64($0) + 1, body: 1, click: 1) }
        case .space: return (0..<3).map { strike(format, seed: UInt64($0) + 20, body: 1.6, click: 0.6) }
        case .backspace: return [strike(format, seed: 40, body: 0.7, click: 1.2)]
        case .bell: return [bell(format)]
        case .carriageReturn: return [ratchet(format)]
        case .feed: return [ratchet(format, clicks: 3)]
        case .hum: return []
        }
    }

    private static func buffer(_ format: AVAudioFormat, seconds: Double, _ f: (Int, Double) -> Double) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(seconds * format.sampleRate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        let sr = format.sampleRate
        for i in 0..<Int(n) {
            let v = Float(max(-1, min(1, f(i, Double(i) / sr))))
            for ch in 0..<Int(format.channelCount) { b.floatChannelData![ch][i] = v }
        }
        return b
    }

    private static func strike(_ format: AVAudioFormat, seed: UInt64, body: Double, click: Double) -> AVAudioPCMBuffer {
        var rng = SplitMix64(seed: seed)
        let f1 = 1900 + rng.nextUnit() * 900
        let f2 = 3800 + rng.nextUnit() * 1500
        let thud = 110 + rng.nextUnit() * 60
        var lp = 0.0
        return buffer(format, seconds: 0.12) { _, t in
            let noise = rng.nextUnit() * 2 - 1
            lp += (noise - lp) * 0.35
            let c = lp * exp(-t / 0.0025) * 0.9 * click
            let ring = (sin(2 * .pi * f1 * t) * 0.35 + sin(2 * .pi * f2 * t) * 0.18) * exp(-t / 0.012)
            let low = sin(2 * .pi * thud * t) * exp(-t / 0.025) * 0.5 * body
            let rattle = noise * exp(-t / 0.03) * 0.06
            return (c + ring + low + rattle) * 0.7
        }
    }

    private static func bell(_ format: AVAudioFormat) -> AVAudioPCMBuffer {
        buffer(format, seconds: 1.6) { _, t in
            let a = exp(-t / 0.5)
            return (sin(2 * .pi * 2093 * t) * 0.5 + sin(2 * .pi * 5420 * t) * 0.18 * exp(-t / 0.15)
                    + sin(2 * .pi * 3130 * t) * 0.12) * a * 0.45 * min(1, t / 0.001)
        }
    }

    private static func ratchet(_ format: AVAudioFormat, clicks: Int = 9) -> AVAudioPCMBuffer {
        var rng = SplitMix64(seed: 99)
        let duration = 0.08 + Double(clicks) * 0.03
        var lp = 0.0
        return buffer(format, seconds: duration + 0.25) { _, t in
            let noise = rng.nextUnit() * 2 - 1
            lp += (noise - lp) * 0.2
            var v = 0.0
            let period = 0.028
            if t < Double(clicks) * period {
                let local = t.truncatingRemainder(dividingBy: period)
                v += lp * exp(-local / 0.002) * 0.6
                v += sin(2 * .pi * 2600 * local) * exp(-local / 0.004) * 0.12
            }
            let slideEnd = Double(clicks) * period
            v += lp * 0.05 * (t < slideEnd ? 1 : exp(-(t - slideEnd) / 0.02))
            if t > slideEnd {
                let lt = t - slideEnd
                v += (lp * 0.8 * exp(-lt / 0.004) + sin(2 * .pi * 140 * lt) * 0.5 * exp(-lt / 0.04))
            }
            return v * 0.7
        }
    }
}
