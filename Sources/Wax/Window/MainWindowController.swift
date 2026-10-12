import AppKit
import SwiftUI

/// Owns the app's window. While it is open Wax is an ordinary app with a Dock icon;
/// once it closes Wax goes back to living in the menu bar.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let store: PlayerStore
    private let settings: Settings
    private let desk: DeskStore
    private var window: NSWindow?

    init(store: PlayerStore, settings: Settings, desk: DeskStore) {
        self.store = store
        self.settings = settings
        self.desk = desk
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // No control starts out focused; the focus ring appears once Tab is pressed.
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let content = MainWindowView()
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(desk)

        let host = NSHostingController(rootView: content)
        // Left to itself the controller sizes the window to the content plus the title bar.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Wax"
        // The content runs to the top edge, under a title bar that shows only its buttons.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Dragging belongs to the scrubber here, so the window moves by its top edge only.
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.1, green: 0.06, blue: 0.04, alpha: 1)
        window.setContentSize(MainWindowView.size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
