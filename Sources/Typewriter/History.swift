import Foundation

/// Keeps every page as a text file, and a draft of the current page in case of a crash.
enum History {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Typewriter/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var draftURL: URL { directory.deletingLastPathComponent().appendingPathComponent("draft.txt") }

    static func save(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let url = directory.appendingPathComponent("\(f.string(from: Date())).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func recent(limit: Int = 10) -> [(url: URL, preview: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                return (url, oneLine.count > 50 ? String(oneLine.prefix(50)) + "…" : oneLine)
            }
    }

    /// Appends a line to a small diagnostic log next to the history.
    static func log(_ line: String) {
        let url = directory.deletingLastPathComponent().appendingPathComponent("debug.log")
        let entry = "\(Date()) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(entry.data(using: .utf8)!)
            try? h.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func saveDraft(_ text: String) {
        try? text.write(to: draftURL, atomically: true, encoding: .utf8)
    }

    static func loadDraft() -> String? {
        try? String(contentsOf: draftURL, encoding: .utf8)
    }

    static func clearDraft() {
        try? FileManager.default.removeItem(at: draftURL)
    }
}
