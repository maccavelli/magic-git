import Cocoa
import SwiftUI

public class HelpWindowController: NSWindowController {
    public static let shared = HelpWindowController()

    private init() {
        let book = HelpDataLoader.loadBook()
        let hostingController: NSViewController
        if #available(macOS 13.0, *) {
            hostingController = NSHostingController(rootView: HelpView(book: book))
        } else {
            hostingController = NSHostingController(rootView: HelpViewLegacy(book: book))
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Magic Git Support & Help"
        window.contentViewController = hostingController
        window.setFrameAutosaveName("MagicGitHelpWindow")
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showHelpWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
