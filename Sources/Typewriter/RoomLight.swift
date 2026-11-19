import AppKit
import simd

/// The light in the room. The housing of the Mac reflects this light, but the display makes its own:
/// in warm light the real metal looks warmer than its picture. So the hardware images are shown
/// as the metal looks in this light (chromatic adaptation, Bradford). The paper and the lamp stay as they are.
enum RoomLight {
    /// Daylight: the hardware images stay unchanged.
    static let neutral: Double = 6500
    static let range: ClosedRange<Double> = 2200...6500

    /// How the hardware is shown: the temperature of the light on it, and its brightness
    /// as a factor for linear light (1 is the image as it is).
    struct Look: Equatable {
        var kelvin: Double
        var gain: Double
        /// Shift of the light away from the color of a black body, as Duv: negative is toward pink, positive toward green.
        var tint = 0.0
    }

    /// Automatic: the look follows the light sensor and the display brightness. Otherwise the manual values apply.
    static var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: "hardware.roomLight.automatic") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hardware.roomLight.automatic")
            measured = nil
            smoothed = nil
            measure(on: NSScreen.screens.first, notify: false)
            NotificationCenter.default.post(name: Hardware.didChange, object: nil)
        }
    }

    /// Manual color temperature of the room light in Kelvin.
    static var temperature: Double {
        get {
            let ud = UserDefaults.standard
            guard ud.object(forKey: "hardware.roomLight") != nil else { return neutral }
            return min(range.upperBound, max(range.lowerBound, ud.double(forKey: "hardware.roomLight")))
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hardware.roomLight")
            NotificationCenter.default.post(name: Hardware.didChange, object: nil)
        }
    }

    /// Above 1 the picture is brighter than the image: needed on a dark display, where the image as it is
    /// looks darker than the housing. The range above 1 is small: the metal in warm light is already as red as
    /// the display can show, so more brightness only makes it white.
    static let brightnessRange: ClosedRange<Double> = 0.15...1.12

    /// Manual brightness of the hardware, as the eye sees it (1 is the image as it is).
    static var brightness: Double {
        get {
            let ud = UserDefaults.standard
            guard ud.object(forKey: "hardware.brightness") != nil else { return 1 }
            return min(brightnessRange.upperBound, max(brightnessRange.lowerBound, ud.double(forKey: "hardware.brightness")))
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hardware.brightness")
            NotificationCenter.default.post(name: Hardware.didChange, object: nil)
        }
    }

    static let tintRange: ClosedRange<Double> = -100...100
    /// One step of the tint setting as Duv.
    private static let tintUnit = 0.0004

    /// Manual tint of the room light: positive is toward pink, negative toward green. 100 is a Duv of 0.04.
    static var tint: Double {
        get { min(tintRange.upperBound, max(tintRange.lowerBound, UserDefaults.standard.double(forKey: "hardware.tint"))) }
        set {
            UserDefaults.standard.set(newValue, forKey: "hardware.tint")
            NotificationCenter.default.post(name: Hardware.didChange, object: nil)
        }
    }

    /// Brightness as the eye sees it, to and from a factor for linear light.
    private static let gamma = 2.2
    static func perceived(_ gain: Double) -> Double { pow(gain, 1 / gamma) }

    /// The look in use: the measured one in automatic mode, when there is a measurement.
    static var look: Look {
        if automatic, let measured { return measured }
        return Look(kelvin: temperature.rounded(), gain: pow(brightness, gamma), tint: -tint * tintUnit)
    }

    /// True when the look in use comes from the sensor.
    static var isMeasured: Bool { automatic && measured != nil }

    // MARK: Automatic

    // The automatic look is a fit to matches made by eye on a rose gold MacBook Air. It is not a model of the
    // luminance: next to the bright paper on a bright display the picture needs more light than the real housing has.
    //
    // Lamp light of about 24 lux and 2650 K:
    //   display brightness   16/16     8/16      4/16      1/16
    //   picture brightness   61 %      74 %      104 %     109 % (the limit)
    //   color                3550 K    3550 K    2700 K    2700 K
    // Very warm light of 25 lux and 1950 K, display 11/16: 3100 K, tint 28, brightness 26 %.

    private static let neutralMired = 1e6 / neutral

    /// The color change that is applied, in mired, for the color change of the room light. The eye adapts
    /// only in part, and less the warmer the light is: the applied change levels off.
    private static func appliedShift(_ shift: Double, display level: Double) -> Double {
        let bright = shift > 0 ? 238 * (1 - exp(-shift / 290)) : 0.58 * shift
        // On a bright display the eye stays adapted to the display; on a dark display it adapts to the room.
        let dark = min(0.94, max(0.58, 0.94 - (level - 0.25) / 0.25 * 0.36)) / 0.58
        return shift > 0 ? min(shift, bright * dark) : bright
    }

    /// How far the light is warmer than normal lamp light: 0 at 2650 K and above, 1 at 1950 K.
    /// In such light the housing looks more pink and darker than the black body color alone gives.
    private static func warmth(_ shift: Double) -> Double {
        min(1.4, max(0, (shift - 223.5) / 135))
    }

    /// The brightness of the picture as the eye sees it. It falls with the display brightness and rises
    /// slowly with the room light. Most matches were made near 24 lux: the exponent for other light is an
    /// estimate, set so that the picture is unchanged in daylight on a bright display.
    private static func pictureBrightness(lux: Double, display level: Double, warmth: Double) -> Double {
        // Below 4 of 16 steps the picture cannot follow the housing: more brightness makes the metal pale.
        // There it rises only a little, as in the matches.
        let shape = level >= 0.25 ? 0.47 + 0.14 / level : 1.03 + 0.06 * (0.25 - level) / 0.1875
        let value = pow(lux / 24, 0.2) * shape * pow(0.37, warmth)
        return min(brightnessRange.upperBound, max(brightnessRange.lowerBound, value))
    }

    /// The carriage is also lit by its own lamp, so the room light changes it less than the rail:
    /// this part of the look of the rail is applied to it.
    private static let carriageShare = 0.5

    static func carriageLook(_ look: Look) -> Look {
        Look(kelvin: 1e6 / (neutralMired + (1e6 / look.kelvin - neutralMired) * carriageShare),
             gain: pow(look.gain, carriageShare), tint: look.tint * carriageShare)
    }

    private static var measured: Look?
    /// The last values from the sensor and the display, also in manual mode. Nil when the screen has no sensor.
    private(set) static var reading: (lux: Double, kelvin: Double, display: Double)?
    private static var smoothed: (mired: Double, logLux: Double, time: Date)?

    /// Reads the light sensor and the display brightness, and updates the look in automatic mode.
    /// The sensor sits next to the built-in display, so on another screen the manual values apply.
    /// Posts `Hardware.didChange` when the look changed enough to see it.
    static func measure(on screen: NSScreen?, notify: Bool = true) {
        reading = nil
        if let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           CGDisplayIsBuiltin(id) != 0, let level = Sensors.displayBrightness(id), let light = Sensors.ambientLight() {
            reading = (light.lux, light.kelvin, level)
        }
        guard automatic else { return }
        var next: Look?
        if let (lux, sensorKelvin, level) = reading {
            let light = (lux: lux, kelvin: sensorKelvin)
            // In very low light the sensor cannot tell the color: keep the last one.
            var mired = light.lux >= 1 ? 1e6 / min(8000, max(1800, light.kelvin)) : (smoothed?.mired ?? 1e6 / neutral)
            var logLux = log(max(0.1, light.lux))
            // Smooth the values while the page is open. After a pause the first reading counts as it is.
            if let s = smoothed, Date().timeIntervalSince(s.time) < 5 {
                mired = s.mired + (mired - s.mired) * 0.35
                logLux = s.logLux + (logLux - s.logLux) * 0.35
            }
            smoothed = (mired, logLux, Date())
            let shift = mired - neutralMired, warm = warmth(shift)
            let kelvin = 1e6 / (neutralMired + appliedShift(shift, display: level))
            let gain = pow(pictureBrightness(lux: exp(logLux), display: level, warmth: warm), gamma)
            next = Look(kelvin: (kelvin / 50).rounded() * 50, gain: gain, tint: -(28 * warm).rounded() * tintUnit)
        } else {
            smoothed = nil
        }
        // Small changes are not applied, so the picture does not flicker.
        if let a = measured, let b = next, abs(a.kelvin - b.kelvin) < 100, abs(log(a.gain / b.gain)) < 0.07,
           abs(a.tint - b.tint) < 3 * tintUnit { return }
        guard next != measured else { return }
        measured = next
        if notify { NotificationCenter.default.post(name: Hardware.didChange, object: nil) }
    }

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

    private static let toLinear: [Double] = (0..<256).map {
        let v = Double($0) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private static let toSRGB: [UInt8] = (0...4095).map {
        let v = Double($0) / 4095
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8((s * 255).rounded())
    }

    /// The image as it looks in the room light. `base` is the color of the metal in the image (sRGB).
    ///
    /// The image is split into the metal and its highlights (the part that goes from the metal color toward
    /// white). The metal gets the color and the brightness of the look. The highlights are reflections of the
    /// lamp: they get the color of the light and lose less brightness, so they stay bright on dark metal.
    /// Metal colors too bright for the display go toward white.
    static func adapt(_ image: CGImage, to look: Look, base: (r: Double, g: Double, b: Double)) -> CGImage? {
        guard abs(look.kelvin - neutral) > 1 || abs(look.gain - 1) > 0.001 || look.tint != 0 else { return image }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let light = matrix(look.kelvin, duv: look.tint)
        let m = light * look.gain
        let luma = SIMD3(0.2126729, 0.7151522, 0.0721750)
        // The color of the light, as bright as the display can show it, times the brightness of the highlights.
        func encode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        let white = simd_max(light * SIMD3(1, 1, 1), SIMD3(repeating: 0))
        let glint = white / white.max() * min(1, pow(look.gain, 0.5))
        let highlight = SIMD3(encode(glint.x), encode(glint.y), encode(glint.z)) * 255
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
