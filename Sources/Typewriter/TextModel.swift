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

    private func relayout() {
        var lines: [[PlacedGlyph]] = [[]]
        var positions: [(line: Int, col: Int)?] = Array(repeating: nil, count: chars.count)
        func place(_ i: Int) {
            let line = lines.count - 1
            positions[i] = (line, lines[line].count)
            lines[line].append(PlacedGlyph(col: lines[line].count, char: chars[i], style: styles[i]))
        }
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == "\n" {
                lines.append([])
                i += 1
                continue
            }
            if c == " " {
                if lines[lines.count - 1].count >= columns {
                    lines.append([]) // The space at the margin becomes the line break.
                } else {
                    place(i)
                }
                i += 1
                continue
            }
            var j = i
            while j < n, chars[j] != " ", chars[j] != "\n" { j += 1 }
            let wordLength = j - i
            let used = lines[lines.count - 1].count
            if used > 0, used + wordLength > columns, wordLength <= columns {
                lines.append([])
            }
            for k in i..<j {
                if lines[lines.count - 1].count >= columns { lines.append([]) }
                place(k)
            }
            i = j
        }
        layout = Layout(lines: lines, positions: positions,
                        caretLine: lines.count - 1, caretCol: lines[lines.count - 1].count)
    }
}
