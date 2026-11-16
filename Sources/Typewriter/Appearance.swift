import CoreGraphics
import Foundation

/// A color of Apple hardware. The values are the mid tone of the anodized aluminum.
struct HardwareColor: Equatable {
    let name: String
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat

    func scaled(_ f: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: min(1, r * f), green: min(1, g * f), blue: min(1, b * f), alpha: alpha)
    }

    /// Mixes the color with white, for highlights.
    func lifted(_ t: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r + (1 - r) * t, green: g + (1 - g) * t, blue: b + (1 - b) * t, alpha: alpha)
    }

    static let all: [HardwareColor] = [
        // MacBook
        HardwareColor(name: "Silver", r: 0.86, g: 0.865, b: 0.875),
        HardwareColor(name: "Space Gray", r: 0.47, g: 0.475, b: 0.49),
        HardwareColor(name: "Space Black", r: 0.19, g: 0.19, b: 0.2),
        HardwareColor(name: "Gold", r: 0.9, g: 0.8, b: 0.73),
        HardwareColor(name: "Starlight", r: 0.89, g: 0.86, b: 0.8),
        HardwareColor(name: "Midnight", r: 0.19, g: 0.22, b: 0.27),
        HardwareColor(name: "Sky Blue", r: 0.77, g: 0.83, b: 0.87),
        // iMac
        HardwareColor(name: "Blue", r: 0.44, g: 0.57, b: 0.74),
        HardwareColor(name: "Green", r: 0.5, g: 0.66, b: 0.57),
        HardwareColor(name: "Pink", r: 0.89, g: 0.6, b: 0.62),
        HardwareColor(name: "Yellow", r: 0.94, g: 0.81, b: 0.46),
        HardwareColor(name: "Orange", r: 0.93, g: 0.57, b: 0.4),
        HardwareColor(name: "Purple", r: 0.63, g: 0.56, b: 0.76),
    ]
}

/// Which part of the typewriter gets the hardware color.
enum ColoredPart: String, CaseIterable {
    case carriage, rod, both

    var title: String {
        switch self {
        case .carriage: return "Carriage"
        case .rod: return "Rod"
        case .both: return "Carriage and Rod"
        }
    }
}

enum Appearance {
    static var color: HardwareColor {
        get {
            let name = UserDefaults.standard.string(forKey: "hardwareColor")
            return HardwareColor.all.first { $0.name == name } ?? HardwareColor.all[0]
        }
        set { UserDefaults.standard.set(newValue.name, forKey: "hardwareColor") }
    }

    static var part: ColoredPart {
        get { ColoredPart(rawValue: UserDefaults.standard.string(forKey: "coloredPart") ?? "") ?? .carriage }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "coloredPart") }
    }

    static func cycleColor(_ step: Int) {
        let all = HardwareColor.all
        let i = all.firstIndex(of: color) ?? 0
        color = all[(i + step + all.count) % all.count]
    }

    static func cyclePart(_ step: Int) {
        let all = ColoredPart.allCases
        let i = all.firstIndex(of: part) ?? 0
        part = all[(i + step + all.count) % all.count]
    }

    static var carriageColored: Bool { part != .rod }
    static var rodColored: Bool { part != .carriage }
}
