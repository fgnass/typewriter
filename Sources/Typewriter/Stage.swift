import AppKit
import WebKit

/// Debug aid for the website video (TYPEWRITER_STAGE=path/to/page.html): a web page full screen in front of
/// everything except the typewriter page, so the recording shows only made-up content. The page must have
/// a focused text field and a global `insertText(text)` function; the text of the page goes there.
final class Stage {
    static var shared: Stage?

    private final class StageWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private let window: NSWindow
    private let web: WKWebView

    init?(path: String) {
        guard let screen = NSScreen.screens.first else { return nil }
        let url = URL(fileURLWithPath: path)
        window = StageWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        // Above the menu bar and the Dock, below the typewriter page.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        web = WKWebView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.contentView = web
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func show() {
        NSCursor.hide()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focus()
    }

    func focus() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
    }

    func insert(_ text: String) {
        focus()
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("insertText(\(json)[0])")
    }
}
