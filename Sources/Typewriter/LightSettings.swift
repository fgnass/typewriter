import Foundation
import CoreGraphics

/// The adjustable parameters of the writing light. They are stored in the user defaults.
struct LightSettings: Equatable {
    /// Full opening angle of the beam, in degrees.
    var spread: Double
    /// Width of the soft side edges, as a fraction of the half angle.
    var softness: Double
    /// Strength of the light. 0 turns off only the warm light; shadows stay.
    var brightness: Double
    /// Reach of the light, as a fraction of the visible paper height.
    var reach: Double
    /// Color temperature in Kelvin.
    var temperature: Double
    /// Brightness of the cool light on the paper outside the lamp.
    var ambient: Double
    /// Tilt of the beam in degrees. Fixed at 0: the beam is symmetric.
    var tilt: Double

    static let defaults = LightSettings(spread: 120, softness: 0.25, brightness: 1, reach: 1.1, temperature: 3600, ambient: 0.75, tilt: 0)

    struct Parameter {
        let key: WritableKeyPath<LightSettings, Double>
        let title: String
        let range: ClosedRange<Double>
        let format: (Double) -> String
    }

    static let parameters: [Parameter] = [
        Parameter(key: \.spread, title: "Spread", range: 40...170, format: { "\(Int($0))°" }),
        Parameter(key: \.softness, title: "Edge Softness", range: 0.02...1, format: { "\(Int($0 * 100)) %" }),
        Parameter(key: \.brightness, title: "Brightness", range: 0...1.5, format: { "\(Int($0 * 100)) %" }),
        Parameter(key: \.reach, title: "Reach", range: 0.15...1.5, format: { "\(Int($0 * 100)) %" }),
        Parameter(key: \.temperature, title: "Color Temperature", range: 2000...6500, format: { "\(Int($0)) K" }),
        Parameter(key: \.ambient, title: "Ambient Light", range: 0.5...1, format: { "\(Int($0 * 100)) %" }),
    ]

    static let didChange = Notification.Name("LightSettingsDidChange")

    static var current: LightSettings {
        get {
            var s = defaults
            let ud = UserDefaults.standard
            for p in parameters {
                let name = "light." + p.title
                if ud.object(forKey: name) != nil { s[keyPath: p.key] = ud.double(forKey: name) }
            }
            return s
        }
        set {
            for p in parameters { UserDefaults.standard.set(newValue[keyPath: p.key], forKey: "light." + p.title) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Light color for the temperature, normalized so that the brightest channel is 1.
    /// Mixed with white, so the light stays an ivory tint and does not become a yellow filter.
    var color: (r: Double, g: Double, b: Double) {
        let t = temperature / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        let c = [r, g, b].map { max(0, min(255, $0)) }
        let m = c.max() ?? 255
        let tint = 0.55
        func mixWhite(_ v: Double) -> Double { 1 - tint + tint * v / m }
        return (mixWhite(c[0]), mixWhite(c[1]), mixWhite(c[2]))
    }

    var cgColor: CGColor {
        let c = color
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}
