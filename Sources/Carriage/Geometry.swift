import CoreGraphics

/// Positions in the carriage images (1774 × 887 px, origin top left). All carriage layers share this canvas.
public enum CarriageGeometry {
    /// The body is made taller than in the original images: a flat slice of its front is stretched.
    public static let bodyExtension: CGFloat = 100
    /// Rows of the original image: the slice between them is stretched by `bodyExtension`.
    public static let stretchTop: CGFloat = 615
    public static let stretchBottom: CGFloat = 672
    public static let canvas = CGSize(width: 1774, height: 887 + bodyExtension)
    /// The fin sits further left than in the original images, so the carriage does not look like a hand
    /// with the thumb up: `finShift` columns of the plain body left of the fin are taken out (from
    /// `shiftStart` on), and the plain foot right of the fin is stretched by the same amount.
    public static let finShift: CGFloat = 240
    public static let shiftStart: CGFloat = 740
    /// The plain part of the foot that is stretched.
    public static let footStretch: ClosedRange<CGFloat> = 1400...1500
    /// The straight part of the fin, which covers the cell of the next character.
    public static let finLeft: CGFloat = 1223 - finShift
    public static let finRight: CGFloat = 1356 - finShift
    public static let finCenter: CGFloat = 1290 - finShift
    /// The fin is shorter than in the original images: `finCut` rows are taken out of its straight part,
    /// starting at `finCutRow`, and everything above moves down.
    public static let finCut: CGFloat = 48
    public static let finCutRow: CGFloat = 260
    public static let finTop: CGFloat = 190 + finCut
    /// The carriage sits this much higher on the rail than in the original design (image pixels).
    public static let raise: CGFloat = 48
    /// The long body.
    public static let bodyLeft: CGFloat = 178
    public static let bodyRight: CGFloat = 1595
    public static let bodyTop: CGFloat = 492
    public static let bodyBottom: CGFloat = 706 + bodyExtension
    /// The lamp strip along the top edge of the body.
    public static let lampStart = CGPoint(x: 226, y: 503)
    public static let lampEnd = CGPoint(x: 1134 - finShift, y: 500)
    /// The status dot in the status image. The scene draws it elsewhere: see `PaperScene.statusDot`.
    public static let status = CGPoint(x: 1300 - finShift, y: 578)
    /// The lamp strip runs on behind the fin; this is its visible part on the foot right of the fin.
    public static let rightLampStart: CGFloat = 1370 - finShift
    /// Rows around the slot of the lamp strip, at the top edge of the body.
    public static let lampSlotRows = 494..<511
    public static let rightLampEnd: CGFloat = 1545
}

/// Rows of the rail band (origin top left). The band is built from the carriage material, so rail and carriage
/// look exactly the same: the lip from the top edge of the carriage, the face from its front. Only the dark
/// groove and the fine highlight below it come from the rail image.
public enum RailGeometry {
    public static let top: CGFloat = 0
    public static let grooveTop: CGFloat = 60
    public static let grooveBottom: CGFloat = 78
    public static let bottom: CGFloat = 201

    /// Source rows in the original carriage image (1774 × 887).
    public static let lipSourceRows = 492..<552        // top edge with its polished chamfer, on the foot
    public static let lipSourceColumns = 1385..<1540
    public static let faceSourceRows = 560..<680       // plain front of the body
    public static let faceSourceColumns = 300..<1100
    /// Source rows in the rail image: the dark groove and the highlight right below it.
    public static let grooveSourceRows = 337..<355
    public static let highlightSourceRows = 355..<358
}

/// The hardware colors. The images for each color are made at build time by `hardware-assets`,
/// tinted from the rose gold originals in Resources/Fin.
public enum HardwareColors {
    public typealias RGB = (r: Double, g: Double, b: Double)
    /// MacBook colors first, then MacBook Neo colors. nil means the original rose gold.
    public static let all: [(id: String, title: String, color: RGB?)] = [
        ("silver", "Silver", (0.86, 0.865, 0.875)),
        ("space-gray", "Space Gray", (0.47, 0.475, 0.49)),
        ("space-black", "Space Black", (0.2, 0.2, 0.21)),
        ("gold", "Rose Gold", nil),
        ("starlight", "Starlight", (0.89, 0.86, 0.8)),
        ("midnight", "Midnight", (0.19, 0.22, 0.27)),
        ("sky-blue", "Sky Blue", (0.77, 0.83, 0.87)),
        ("blush", "Blush", (0.9, 0.72, 0.75)),
        ("indigo", "Indigo", (0.33, 0.35, 0.56)),
        ("citrus", "Citrus", (0.86, 0.86, 0.56)),
    ]
    /// Mean color of the rose gold metal: the reference for tinting and the swatch for rose gold.
    public static let roseGold: RGB = (0.86, 0.72, 0.64)
    /// Mean color of the rose gold rail, measured on its lip and face.
    public static let railRoseGold: RGB = (0.875, 0.678, 0.632)
}
