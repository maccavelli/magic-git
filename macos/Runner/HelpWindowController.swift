import Cocoa
import SwiftUI

public class HelpWindowController: NSWindowController {
    public static let shared = HelpWindowController()

    private init() {
        let helpView = HelpView(book: HelpDataLoader.loadBook())
        let hostingController = NSHostingController(rootView: helpView)

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
