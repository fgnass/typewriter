import Foundation
import CoreGraphics
import ImageIO

/// Registration data of a carriage image, normalized to the image size (y goes down).
struct CarriageRegistration: Decodable {
    let printX, printY: Double
    let ceramicLeft, ceramicRight: Double
    let left, right, top, bottom: Double
    let width, height: Double
}

/// Registration data of a rail image, normalized to the image size (y goes down).
struct RailRegistration: Decodable {
    let top, bottom: Double
    let grooveTop, grooveBottom, groove: Double
    let width, height: Double
}

/// One hardware color: the carriage, the rail, and where they line up.
struct HardwareVariant {
    let id: String
    let title: String
    let carriage: CGImage
    let rail: CGImage
    let carriageReg: CarriageRegistration
    let railReg: RailRegistration
}

enum Hardware {
    /// MacBook colors first, then MacBook Neo colors.
    static let ids: [(id: String, title: String)] = [
        ("silver", "Silver"), ("space-gray", "Space Gray"), ("space-black", "Space Black"),
        ("gold", "Gold"), ("starlight", "Starlight"), ("midnight", "Midnight"), ("sky-blue", "Sky Blue"),
        ("blush", "Blush"), ("indigo", "Indigo"), ("citrus", "Citrus"),
    ]

    private static let directory = Bundle.main.resourceURL?.appendingPathComponent("Hardware")

    private static let registry: [String: [String: Any]] = {
        guard let url = directory?.appendingPathComponent("registration.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        return json
    }()

    private static var cache: [String: HardwareVariant] = [:]

    static var currentID: String {
        get {
            let id = UserDefaults.standard.string(forKey: "hardware") ?? "gold"
            return ids.contains { $0.id == id } ? id : "gold"
        }
        set { UserDefaults.standard.set(newValue, forKey: "hardware") }
    }

    static var current: HardwareVariant? { variant(currentID) }

    static func cycle(_ step: Int) {
        let i = ids.firstIndex { $0.id == currentID } ?? 0
        currentID = ids[(i + step + ids.count) % ids.count].id
    }

    static func variant(_ id: String) -> HardwareVariant? {
        if let v = cache[id] { return v }
        guard let dir = directory?.appendingPathComponent(id),
              let carriage = image(dir.appendingPathComponent("carriage.png")),
              let rail = image(dir.appendingPathComponent("rail.png")),
              let entry = registry[id],
              let c = decode(CarriageRegistration.self, entry["carriage"]),
              let r = decode(RailRegistration.self, entry["rail"]) else { return nil }
        let v = HardwareVariant(id: id, title: ids.first { $0.id == id }?.title ?? id,
                                carriage: carriage, rail: rail, carriageReg: c, railReg: r)
        cache[id] = v
        return v
    }

    static let paper: CGImage? = directory.flatMap { image($0.appendingPathComponent("paper.png")) }

    private static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
