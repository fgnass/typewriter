import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import ImageIO
import Carriage

/// The images of one hardware color, made at build time by `hardware-assets`.
struct HardwareVariant {
    let id: String
    let title: String
    let carriage: CGImage
    let rail: CGImage
    let lamp: CGImage
    let status: CGImage
    let grilleHole: CGImage
    /// How the room lights the hardware: the scene needs it for the light of the paper on the rail.
    var lighting = RoomLight.Lighting()
}

enum Hardware {
    static var ids: [(id: String, title: String, color: HardwareColors.RGB?)] { HardwareColors.all }

    private static let directory = Bundle.main.resourceURL?.appendingPathComponent("Fin")
    private static let generated = Bundle.main.resourceURL?.appendingPathComponent("Hardware")
    private static var cache: [String: HardwareVariant] = [:]

    /// The chosen color, or the color of this Mac when the user has not chosen one.
    static var currentID: String {
        get {
            let id = UserDefaults.standard.string(forKey: "hardware") ?? detectedID ?? "gold"
            return ids.contains { $0.id == id } ? id : "gold"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hardware")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static let didChange = Notification.Name("HardwareDidChange")

    /// The housing color of this Mac, as macOS knows it for the device picture in "About This Mac":
    /// the model and the enclosure color number map to a device type such as
    /// "com.apple.macbookair-late-2020-gold", whose name contains the color.
    static let detectedID: String? = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(cString: buf)
        typealias MGCopyAnswer = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
        guard !model.isEmpty,
              let lib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW),
              let sym = dlsym(lib, "MGCopyAnswer"),
              let answer = unsafeBitCast(sym, to: MGCopyAnswer.self)("DeviceEnclosureColor" as CFString)?.takeRetainedValue()
        else { return nil }
        let color = "\(answer)"
        guard let type = UTType(tag: "\(model)@ECOLOR=\(color)", tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
        else { return nil }
        let names = ([type.identifier] + type.supertypes.map(\.identifier)).joined(separator: " ").lowercased()
        // Longer names first, so "sky-blue" is not taken for "blue" and "space-gray" not for "gray".
        let keywords: [(String, String)] = [
            ("space-black", "space-black"), ("space-gray", "space-gray"), ("space-grey", "space-gray"),
            ("sky-blue", "sky-blue"), ("midnight", "midnight"), ("starlight", "starlight"),
            ("rose-gold", "gold"), ("gold", "gold"), ("silver", "silver"),
            ("blush", "blush"), ("pink", "blush"), ("indigo", "indigo"), ("citrus", "citrus"), ("yellow", "citrus"),
        ]
        return keywords.first { names.contains($0.0) }?.1
    }()

    /// The color for a preview circle.
    static func swatchColor(_ id: String) -> NSColor {
        let c = ids.first { $0.id == id }?.color ?? HardwareColors.roseGold
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// The chosen color as it looks in the room light.
    static var current: HardwareVariant? {
        let id = currentID
        let base = ids.first { $0.id == id }?.color ?? HardwareColors.railRoseGold
        let lighting = RoomLight.lighting(base: base)
        if let a = adapted, a.id == id, a.variant.lighting == lighting { return a.variant }
        guard let v = variant(id) else { return nil }
        // The lamp and the status dot make their own light, so they stay as they are.
        let lit = HardwareVariant(id: v.id, title: v.title,
                                  carriage: RoomLight.adapt(v.carriage, with: lighting.carriage, base: base) ?? v.carriage,
                                  rail: RoomLight.adapt(v.rail, with: lighting.rail, base: base) ?? v.rail,
                                  lamp: v.lamp, status: v.status,
                                  grilleHole: RoomLight.adapt(v.grilleHole, with: lighting.carriage, base: base) ?? v.grilleHole,
                                  lighting: lighting)
        adapted = (id, lit)
        return lit
    }

    /// The last variant made for a room light, so a redraw does not make it again.
    private static var adapted: (id: String, variant: HardwareVariant)?

    static func variant(_ id: String) -> HardwareVariant? {
        if let v = cache[id] { return v }
        guard let entry = ids.first(where: { $0.id == id }), let dir = generated,
              let carriage = image(dir.appendingPathComponent("\(id)/carriage.png")),
              let rail = image(dir.appendingPathComponent("\(id)/rail.png")),
              let lamp = image(dir.appendingPathComponent("lamp.png")),
              let status = image(dir.appendingPathComponent("status.png")),
              let hole = image(dir.appendingPathComponent("\(id)/grille-hole.png")) else { return nil }
        let v = HardwareVariant(id: id, title: entry.title, carriage: carriage, rail: rail,
                                lamp: lamp, status: status, grilleHole: hole)
        cache[id] = v
        return v
    }

    static let paper: CGImage? = directory.flatMap { image($0.appendingPathComponent("paper.png")) }

    private static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
