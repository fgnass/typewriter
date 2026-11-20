import AppKit
import simd

/// The light on the housing of the Mac. The housing reflects the light around it, but the display makes its
/// own: in warm or weak light the real metal looks different from its picture. So the hardware images are
/// shown as the metal looks in this light. The paper and the lamp stay as they are.
enum RoomLight {
    /// Daylight: the hardware images stay unchanged.
    static let neutral: Double = 6500
    static let range: ClosedRange<Double> = 2200...6500

    /// How the hardware is lit. The matrices change a color of the image (linear sRGB) to the color shown.
    struct Lighting: Equatable {
        var rail = matrix_identity_double3x3
        var carriage = matrix_identity_double3x3
        /// Light of the paper on the rail below it: an sRGB color that is added at the top edge of the rail.
        var glow = SIMD3<Double>(repeating: 0)
        /// How dark the ends of the rail are, 0 to 1.
        var edge = 0.0
    }

    // MARK: Settings

    /// Automatic: the lighting follows the light sensor and the display. Otherwise the manual values apply.
    static var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: "hardware.roomLight.automatic") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hardware.roomLight.automatic")
            measured = nil
            smoothed = nil
            measure(on: NSScreen.screens.first, notify: false)
            changed()
        }
    }

    private static func changed() { NotificationCenter.default.post(name: Hardware.didChange, object: nil) }

    private static func value(_ key: String, default fallback: Double, in range: ClosedRange<Double>) -> Double {
        let ud = UserDefaults.standard
        guard ud.object(forKey: key) != nil else { return fallback }
        return min(range.upperBound, max(range.lowerBound, ud.double(forKey: key)))
    }

    /// Manual color temperature of the room light in Kelvin.
    static var temperature: Double {
        get { value("hardware.roomLight", default: neutral, in: range) }
        set { UserDefaults.standard.set(newValue, forKey: "hardware.roomLight"); changed() }
    }

    /// Above 1 the picture is brighter than the image. The range above 1 is small: metal in warm light is
    /// already as red as the display can show, so more brightness only makes it white.
    static let brightnessRange: ClosedRange<Double> = 0.15...1.12

    /// Manual brightness of the hardware, as the eye sees it (1 is the image as it is).
    static var brightness: Double {
        get { value("hardware.brightness", default: 1, in: brightnessRange) }
        set { UserDefaults.standard.set(newValue, forKey: "hardware.brightness"); changed() }
    }

    static let tintRange: ClosedRange<Double> = -100...100
    /// One step of the tint setting as Duv.
    private static let tintUnit = 0.0004

    /// Manual tint of the room light: positive is toward pink, negative toward green. 100 is a Duv of 0.04.
    static var tint: Double {
        get { value("hardware.tint", default: 0, in: tintRange) }
        set { UserDefaults.standard.set(newValue, forKey: "hardware.tint"); changed() }
    }

    /// In automatic mode: how much of the room light reaches the housing, relative to the light at the sensor,
    /// as a power of two. The sensor looks at the user and the housing lies flat, so this depends on where the lamp is.
    static let strengthRange: ClosedRange<Double> = -2...2
    static var strength: Double {
        get { value("hardware.roomLight.strength", default: 0, in: strengthRange) }
        set { UserDefaults.standard.set(newValue, forKey: "hardware.roomLight.strength"); changed() }
    }

    /// Brightness as the eye sees it, to and from a factor for linear light.
    private static let gamma = 2.2
    static func perceived(_ gain: Double) -> Double { pow(max(0, gain), 1 / gamma) }

    private static let luma = SIMD3(0.2126729, 0.7151522, 0.0721750)
    private static func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func encode(_ v: Double) -> Double {
        let c = min(1, max(0, v))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
    static func decode(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(decode(c.x), decode(c.y), decode(c.z)) }
    private static func encode(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(encode(c.x), encode(c.y), encode(c.z)) }

    // MARK: Lighting

    /// The lighting in use for a hardware color (`base`, sRGB).
    static func lighting(base: (r: Double, g: Double, b: Double)) -> Lighting {
        let metal = SIMD3(base.r, base.g, base.b)
        if automatic, let measured { return lighting(measured, metal: metal) }
        // Manual: one light with the chosen color and brightness.
        let gain = pow(brightness, gamma), kelvin = temperature.rounded(), duv = -tint * tintUnit
        guard abs(kelvin - neutral) > 1 || abs(gain - 1) > 0.001 || duv != 0 else { return Lighting() }
        let dark = min(1, max(0, 1 - brightness))
        let light = matrix(kelvin, duv: duv) * gain
        return Lighting(rail: light, carriage: light,
                        glow: metal * 0.16 * dark, edge: dark)
    }

    // The housing next to the display has two lights. The picture must send out the same light as the
    // housing reflects, so both are given relative to the white of the display.
    //
    // 1. The room light, from the sensor. Its part falls when the display gets brighter, because the white
    //    of the display gets brighter and the housing does not.
    // 2. The light of the display itself, which shines on the housing below it. Relative to the white of the
    //    display it does not change with the display brightness. Its color is the color of the picture on
    //    the display: the bright paper and the backdrop around it.
    //
    // In warm lamp light the two together give the rose tone of the real housing: orange from the lamp where
    // the display light is weak, and more neutral below the bright paper.

    /// The room light on the housing relative to the white of the display, at 24 lux and full display brightness.
    /// Found by eye on a rose gold MacBook Air in lamp light of 28 lux and 2100 K: more made the metal too warm.
    private static let roomShare = 0.018
    /// How much of the light at the sensor reaches the housing. The sensor stands upright and the housing lies flat.
    /// Lamp light comes from above: it is weak at the sensor and strong on the housing. Daylight comes from the
    /// side through a window: it is strong at the sensor and weak on the housing. The color tells the two apart.
    /// Found by eye: in daylight of 420 lux and 9000 K the picture brightness that matched was 40 % to 47 %,
    /// nearly the light of the display alone.
    private static func reach(mired: Double) -> Double {
        let lamp = min(1, max(0, (mired - 200) / (333 - 200))) // 0 at 5000 K and cooler, 1 at 3000 K and warmer
        return 0.04 + 0.96 * lamp * lamp * (3 - 2 * lamp)
    }

    /// The part of the room light that grows when the display gets darker. Found by eye.
    private static let roomDimming = 0.25
    /// The part of the display light that the housing next to the display reflects. With the room light it
    /// gives the picture brightness that matched by eye at full display brightness, about 60 %.
    private static let displayShare = 0.45
    /// The part of the paper in the display light, below the paper and far from it. An estimate.
    private static let paperPart = (below: 0.8, far: 0.3)
    /// The light of the paper near the rail, in linear sRGB relative to the white of the display. An estimate.
    private static let paperLight = SIMD3(0.87, 0.87, 0.87)

    /// The mean color of the picture around the paper, in linear sRGB. The scene sets it.
    static var backdrop = decode(SIMD3(0.745, 0.715, 0.79)) * 0.5 {
        didSet { if automatic, simd_distance(backdrop, oldValue) > 0.005 { changed() } }
    }

    private static let neutralMired = 1e6 / neutral

    private static func lighting(_ m: Measurement, metal: SIMD3<Double>) -> Lighting {
        // By the physics the part of the room light is proportional to 1 / display brightness. By eye that was
        // too warm on all steps below the brightest, so only a part of it follows the display brightness.
        let dimming = (1 - roomDimming) + roomDimming / max(m.display, 0.005)
        let amount = roomShare * pow(2, strength) * m.lux / 24 * dimming * reach(mired: m.mired)
        // Light cooler than the white of the display gives no blue metal: the eye is used to daylight.
        let room = matrix(1e6 / max(m.mired, neutralMired)) * amount
        func display(paper part: Double) -> simd_double3x3 {
            // Only the brightness of the backdrop counts. With its color, a purple desktop picture gave silver
            // a pink cast, and the matches by eye in daylight were neutral.
            let around = SIMD3(repeating: simd_dot(luma, backdrop))
            return simd_double3x3(diagonal: (paperLight * part + around * (1 - part)) * displayShare)
        }
        var far = display(paper: paperPart.far) + room, below = display(paper: paperPart.below) + room
        // The display cannot show the metal brighter than its brightest channel allows: more light would only
        // make it pale. So the light is limited to what the metal color can take.
        let surface = decode(metal)
        let top = (below * surface).max()
        if top > 1 { far = far * (1 / top); below = below * (1 / top) }
        let glow = simd_max(encode(below * surface) - encode(far * surface), SIMD3(repeating: 0))
        let level = simd_dot(luma, far * SIMD3(1, 1, 1))
        // The carriage has the same light as the rail. The scene adds the light of the paper to both in the same way.
        return Lighting(rail: far, carriage: far,
                        glow: glow, edge: min(1, max(0, 1 - perceived(level))))
    }

    // MARK: Measurement

    private struct Measurement {
        var lux: Double
        var mired: Double
        /// The white of the display relative to its white at full brightness.
        var display: Double
    }

    private static var measured: Measurement?
    private static var smoothed: (mired: Double, logLux: Double, time: Date)?
    /// The last values from the sensor and the display, also in manual mode. Nil when the screen has no sensor.
    private(set) static var reading: (lux: Double, kelvin: Double, display: Double)?

    /// Reads the light sensor and the display brightness, and updates the lighting in automatic mode.
    /// The sensor sits next to the built-in display, so on another screen the manual values apply.
    /// Posts `Hardware.didChange` when the values changed enough to see it.
    static func measure(on screen: NSScreen?, notify: Bool = true) {
        reading = nil
        var white = 1.0
        if let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           CGDisplayIsBuiltin(id) != 0, let level = Sensors.displayBrightness(id), let light = Sensors.ambientLight() {
            reading = (light.lux, light.kelvin, level)
            white = Sensors.displayLinearBrightness(id) ?? pow(level, 2)
        }
        guard automatic else { return }
        var next: Measurement?
        if let light = reading {
            // In very low light the sensor cannot tell the color: keep the last one.
            var mired = light.lux >= 1 ? 1e6 / min(8000, max(1800, light.kelvin)) : (smoothed?.mired ?? neutralMired)
            var logLux = log(max(0.1, light.lux))
            // Smooth the values while the page is open. After a pause the first reading counts as it is.
            if let s = smoothed, Date().timeIntervalSince(s.time) < 5 {
                mired = s.mired + (mired - s.mired) * 0.35
                logLux = s.logLux + (logLux - s.logLux) * 0.35
            }
            smoothed = (mired, logLux, Date())
            next = Measurement(lux: exp(logLux), mired: mired, display: white)
        } else {
            smoothed = nil
        }
        // Small changes are not applied, so the picture does not flicker.
        if let a = measured, let b = next, abs(log(a.lux / b.lux)) < 0.07, abs(a.mired - b.mired) < 6,
           abs(log(max(a.display, 0.005) / max(b.display, 0.005))) < 0.04 { return }
        guard next != nil || measured != nil else { return }
        measured = next
        if notify { changed() }
    }

    // MARK: Color

    /// XYZ of the white of a black body at this temperature, with Y = 1 (approximation of Kang et al., 1667 K to 25000 K).
    private static func white(_ kelvin: Double, duv: Double = 0) -> SIMD3<Double> {
        var (x, y) = blackBody(kelvin)
        if duv != 0 {
            // Move across the black body curve in the CIE 1960 diagram, where Duv is defined.
            func uv(_ c: (x: Double, y: Double)) -> SIMD2<Double> {
                SIMD2(4 * c.x, 6 * c.y) / (-2 * c.x + 12 * c.y + 3)
            }
            let here = uv((x, y)), along = simd_normalize(uv(blackBody(kelvin + 10)) - here)
            var across = SIMD2(-along.y, along.x)
            if across.y < 0 { across = -across } // green is up
            let p = here + across * duv
            let d = 2 * p.x - 8 * p.y + 4
            (x, y) = (3 * p.x / d, 2 * p.y / d)
        }
        return SIMD3(x / y, 1, (1 - x - y) / y)
    }

    /// Chromaticity of a black body at this temperature.
    private static func blackBody(_ kelvin: Double) -> (x: Double, y: Double) {
        let t = kelvin
        let x = t < 4000
            ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        let y: Double
        if t < 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t < 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return (x, y)
    }

    /// The matrix for linear sRGB that changes a surface color in daylight to its color in light of this temperature.
    static func matrix(_ kelvin: Double, duv: Double = 0) -> simd_double3x3 {
        let bradford = simd_double3x3(rows: [
            SIMD3(0.8951, 0.2664, -0.1614),
            SIMD3(-0.7502, 1.7135, 0.0367),
            SIMD3(0.0389, -0.0685, 1.0296),
        ])
        let toXYZ = simd_double3x3(rows: [
            SIMD3(0.4124564, 0.3575761, 0.1804375),
            SIMD3(0.2126729, 0.7151522, 0.0721750),
            SIMD3(0.0193339, 0.1191920, 0.9503041),
        ])
        let gain = (bradford * white(kelvin, duv: duv)) / (bradford * white(neutral))
        return toXYZ.inverse * bradford.inverse * simd_double3x3(diagonal: gain) * bradford * toXYZ
    }

    private static let toLinear: [Double] = (0..<256).map { decode(Double($0) / 255) }
    private static let toSRGB: [UInt8] = (0...4095).map { UInt8((encode(Double($0) / 4095) * 255).rounded()) }

    /// The image in a light. `base` is the color of the metal in the image (sRGB).
    ///
    /// The image is split into the metal and its highlights (the part that goes from the metal color toward
    /// white). The metal gets the color and the brightness of the light. The highlights are reflections of the
    /// lamp: they get the color of the light and lose less brightness, so they stay bright on dark metal.
    /// Metal colors too bright for the display go toward white.
    static func adapt(_ image: CGImage, with m: simd_double3x3, base: (r: Double, g: Double, b: Double)) -> CGImage? {
        guard m != matrix_identity_double3x3 else { return image }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let luma = self.luma
        // The color of the light, as bright as the display can show it, times the brightness of the highlights.
        let white = simd_max(m * SIMD3(1, 1, 1), SIMD3(repeating: 0))
        let glint = white / max(white.max(), 0.0001) * min(1, pow(simd_dot(luma, white), 0.5))
        let highlight = encode(glint) * 255
        let floor = min(base.r, base.g, base.b) * 255, span = max(12, 255 - floor)
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: info) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = raw.bindMemory(to: UInt8.self)
            toLinear.withUnsafeBufferPointer { lin in
                toSRGB.withUnsafeBufferPointer { out in
                    for i in stride(from: 0, to: p.count, by: 4) {
                        let alpha = Int(p[i + 3])
                        guard alpha > 0 else { continue }
                        // Remove the alpha, so the curve is applied to the true color.
                        func straight(_ v: UInt8) -> Double { Double(min(255, (Int(v) * 255 + alpha / 2) / alpha)) }
                        var s = SIMD3(straight(p[i]), straight(p[i + 1]), straight(p[i + 2]))
                        // The part of white in the pixel, above the metal color. The images are made this way.
                        let k = min(0.98, max(0, (s.min() - floor) / span))
                        s = simd_clamp((s - SIMD3(repeating: 255 * k)) / (1 - k), SIMD3(repeating: 0), SIMD3(repeating: 255))
                        var c = m * SIMD3(lin[Int(s.x + 0.5)], lin[Int(s.y + 0.5)], lin[Int(s.z + 0.5)])
                        c = simd_max(c, SIMD3(repeating: 0))
                        let top = c.max()
                        if top > 1 {
                            let l = min(1, simd_dot(c, luma))
                            c = SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * ((1 - l) / (top - l))
                        }
                        func premultiplied(_ v: Double, _ glint: Double) -> UInt8 {
                            let metal = Double(out[Int(min(1, max(0, v)) * 4095 + 0.5)])
                            return UInt8((Int(metal * (1 - k) + glint * k + 0.5) * alpha + 127) / 255)
                        }
                        p[i] = premultiplied(c.x, highlight.x)
                        p[i + 1] = premultiplied(c.y, highlight.y)
                        p[i + 2] = premultiplied(c.z, highlight.z)
                    }
                }
            }
            return ctx.makeImage()
        }
    }
}

/// Readings from private system interfaces. Each one is nil when the system does not give it.
enum Sensors {
    /// The brightness setting of a display, 0 to 1.
    static func displayBrightness(_ display: CGDirectDisplayID) -> Double? {
        typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        guard let get = displayServicesGet else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0, value.isFinite else { return nil }
        return Double(min(1, max(0, value)))
    }

    /// The white of a display relative to its white at full brightness, 0 to 1. The brightness setting is not
    /// proportional to the light: at half the setting the display gives about a third of the light.
    static func displayLinearBrightness(_ display: CGDirectDisplayID) -> Double? {
        guard let get = displayServicesGetLinear else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0, value.isFinite, value > 0 else { return nil }
        return Double(min(1, value))
    }

    private static let displayServicesGetLinear: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let sym = dlsym(lib, "DisplayServicesGetLinearBrightness") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    private static let displayServicesGet: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let sym = dlsym(lib, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    /// The room light at the sensor next to the camera: its illuminance and its color temperature.
    static func ambientLight() -> (lux: Double, kelvin: Double)? {
        guard let hid, let service = hid.service,
              let event = hid.copyEvent(service, hid.eventType, 0, 0)?.takeRetainedValue() else { return nil }
        // Fields of the ambient light event: 10 is the color temperature, 11 the illuminance.
        let kelvin = hid.getFloat(event, Int32(hid.eventType << 16 | 10))
        let lux = hid.getFloat(event, Int32(hid.eventType << 16 | 11))
        guard lux.isFinite, kelvin.isFinite, lux >= 0, kelvin > 0 else { return nil }
        return (lux, kelvin)
    }

    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private struct HID {
        let client: AnyObject
        let service: AnyObject?
        let copyEvent: CopyEvent
        let getFloat: GetFloat
        /// kIOHIDEventTypeAmbientLightSensor
        let eventType: Int64 = 12
    }

    private static let hid: HID? = {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
        typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(lib, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(lib, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(lib, "IOHIDEventSystemClientCopyServices"),
              let copyEvent = dlsym(lib, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(lib, "IOHIDEventGetFloatValue"),
              let client = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        // The ambient light sensor: vendor usage page 0xff00, usage 4.
        unsafeBitCast(setMatching, to: SetMatching.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4] as CFDictionary)
        let services = unsafeBitCast(copyServices, to: CopyServices.self)(client)?.takeRetainedValue() as? [AnyObject]
        return HID(client: client, service: services?.first,
                   copyEvent: unsafeBitCast(copyEvent, to: CopyEvent.self), getFloat: unsafeBitCast(getFloat, to: GetFloat.self))
    }()
}
