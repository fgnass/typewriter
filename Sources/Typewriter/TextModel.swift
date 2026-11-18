import Foundation
import CoreGraphics

/// Small random imperfections of one strike, so the text looks typed.
struct StrikeStyle: Hashable {
    var dx: CGFloat
    var dy: CGFloat
    var ink: CGFloat
    var rotation: CGFloat

    /// All strikes are identical: crisp, even and aligned.
    static func random(for char: Character) -> StrikeStyle {
        StrikeStyle(dx: 0, dy: 0, ink: 0.92, rotation: 0)
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A character that was removed with the correction tape. It leaves a faint trace on the paper.
struct Ghost: Hashable {
    let line: Int
    let col: Int
    let char: Character
    let style: StrikeStyle
}

struct PlacedGlyph: Hashable {
    let col: Int
    let char: Character
    let style: StrikeStyle
    /// Number of character cells: 2 for wide characters (CJK, emoji), else 1.
    var cells: Int { TextModel.cells(of: char) }
}

struct Layout {
    var lines: [[PlacedGlyph]]
    /// Visual position of every character index (nil for newlines and swallowed spaces).
    var positions: [(line: Int, col: Int)?]
    var caretLine: Int
    var caretCol: Int
}

final class TextModel {
    let columns: Int
    private(set) var chars: [Character] = []
    private(set) var styles: [StrikeStyle] = []
    private(set) var ghosts: [Ghost] = []
    private(set) var layout: Layout

    init(columns: Int, text: String = "") {
        self.columns = columns
        layout = Layout(lines: [[]], positions: [], caretLine: 0, caretCol: 0)
        insert(text)
    }

    var text: String { String(chars) }
    var isEmpty: Bool { chars.isEmpty }

    func insert(_ s: String) {
        guard !s.isEmpty else { return }
        for c in s {
            chars.append(c)
            styles.append(.random(for: c))
        }
        relayout()
    }

    /// Removes the last character without a trace. Returns false when there is nothing to remove.
    @discardableResult
    func deleteBackward() -> Bool {
        guard !chars.isEmpty else { return false }
        chars.removeLast()
        styles.removeLast()
        relayout()
        return true
    }

    /// Wide characters (East Asian wide and full-width forms, emoji) take two cells, all others one.
    static func cells(of c: Character) -> Int {
        guard let scalar = c.unicodeScalars.first else { return 1 }
        if c.unicodeScalars.count > 1, c.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
            return 2
        }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    private func relayout() {
        var lines: [[PlacedGlyph]] = [[]]
        var used = 0 // Cells used on the last line.
        var positions: [(line: Int, col: Int)?] = Array(repeating: nil, count: chars.count)
        func newLine() {
            lines.append([])
            used = 0
        }
        func place(_ i: Int) {
            let line = lines.count - 1
            positions[i] = (line, used)
            lines[line].append(PlacedGlyph(col: used, char: chars[i], style: styles[i]))
            used += TextModel.cells(of: chars[i])
        }
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == "\n" {
                newLine()
                i += 1
                continue
            }
            if c == " " {
                if used >= columns {
                    newLine() // The space at the margin becomes the line break.
                } else {
                    place(i)
                }
                i += 1
                continue
            }
            var j = i
            var wordCells = 0
            while j < n, chars[j] != " ", chars[j] != "\n" {
                wordCells += TextModel.cells(of: chars[j])
                j += 1
            }
            if used > 0, used + wordCells > columns, wordCells <= columns {
                newLine()
            }
            for k in i..<j {
                if used + TextModel.cells(of: chars[k]) > columns, used > 0 { newLine() }
                place(k)
            }
            i = j
        }
        layout = Layout(lines: lines, positions: positions, caretLine: lines.count - 1, caretCol: used)
    }
}
