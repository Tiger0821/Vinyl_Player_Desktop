import AppKit
import Combine
import SwiftUI

/// Keeps one scene window on every display, in the desktop layers beneath every app window.
///
/// Normally the scene can sit in front of the desktop's files and widgets, hiding them. On
/// Show Desktop it drops behind them, so they appear laid over the scene and the scene takes
/// the place of the wallpaper.
@MainActor
final class DesktopWindowController {
    private let store: PlayerStore
    private let settings: Settings
    private let desk: DeskStore
    private let watcher = ShowDesktopWatcher()
    private var windows: [NSWindow] = []
    private var isVisible = false
    private var coversDesktopItems = true
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?

    init(store: PlayerStore, settings: Settings, desk: DeskStore) {
        self.store = store
        self.settings = settings
        self.desk = desk

        watcher.onChange = { [weak self] showing in
            Log.debug("show desktop: \(showing ? "on — files and widgets come forward" : "off")")
            self?.applyLevel()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuild()
            }
        }

        settings.$coversDesktopItems
            .removeDuplicates()
            .sink { [weak self] covers in
                self?.coversDesktopItems = covers
                self?.applyLevel()
            }
            .store(in: &cancellables)

        settings.$isSceneVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.isVisible = visible
                self?.rebuild()
            }
            .store(in: &cancellables)
    }

    /// In front of the desktop's files and widgets only when asked to be, and never while
    /// the desktop is being shown.
    private func applyLevel() {
        // There is only something to watch for while the scene is hiding the desktop's things.
        if isVisible, coversDesktopItems {
            watcher.start()
        } else {
            watcher.stop()
        }

        let level = DesktopWindow.level(coveringDesktopItems: coversDesktopItems && !watcher.isShowingDesktop)
        for window in windows where window.level != level {
            window.level = level
            window.orderFrontRegardless()
        }
    }

    /// Displays come, go and change size; starting over is simpler than patching windows up.
    private func rebuild() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()

        if isVisible {
            for screen in NSScreen.screens {
                let window = DesktopWindow(screen: screen)
                let scene = SceneRootView()
                    .environmentObject(store)
                    .environmentObject(settings)
                    .environmentObject(desk)
                let host = NSHostingView(rootView: scene)
                // Without this the hosting view tries to resize the window to fit its content.
                host.sizingOptions = []
                host.frame = NSRect(origin: .zero, size: screen.frame.size)
                host.autoresizingMask = [.width, .height]
                window.contentView = host
                window.setFrame(screen.frame, display: true)
                window.orderFrontRegardless()
                windows.append(window)
            }
        }
        applyLevel()
    }
}

private final class DesktopWindow: NSWindow {
    /// Either way the window stays far below ordinary app windows.
    static func level(coveringDesktopItems: Bool) -> NSWindow.Level {
        if coveringDesktopItems {
            // Desktop widgets are drawn two steps above Finder's icons; clear both.
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 5)
        }
        // One step above the wallpaper, which leaves it under the icons and widgets.
        return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)

        level = Self.level(coveringDesktopItems: false)
        // On every Space, absent from window cycling, and — like the wallpaper it stands in
        // for — left where it is by Show Desktop and Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Clicks fall through to the desktop.
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        // Hiding the app, or another app's "Hide Others", must not take the scene with it.
        canHide = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Notices when Show Desktop is in effect.
///
/// macOS tells no one when the desktop is shown. But the Dock sweeps windows aside to show
/// it, so this keeps a small invisible window of its own for the Dock to sweep, and checks a
/// few times a second whether it has been moved.
@MainActor
final class ShowDesktopWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var isShowingDesktop = false

    private var decoy: NSWindow?
    private var timer: Timer?
    /// Where the decoy was last seen out of place. Show Desktop holds it still; a swipe
    /// between Spaces carries it past, never in the same spot twice.
    private var lastDisplaced: CGPoint?

    func start() {
        guard decoy == nil, let screen = NSScreen.main else { return }

        let side: CGFloat = 80
        let frame = NSRect(x: screen.frame.midX - side / 2, y: screen.frame.midY - side / 2, width: side, height: side)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 6)
        // "Transient" is what makes the Dock treat it as a window to clear away.
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.canHide = false
        window.animationBehavior = .none
        window.orderFrontRegardless()
        decoy = window

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        decoy?.close()
        decoy = nil
        lastDisplaced = nil
        set(false)
    }

    private func check() {
        guard let decoy, let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(decoy.windowNumber)) as? [[String: Any]],
              let info = list.first,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo)
        else { return }

        // The window server measures from the top of the primary display.
        let home = CGPoint(x: decoy.frame.minX, y: primary.frame.maxY - decoy.frame.maxY)
        let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
        let isDisplaced = abs(bounds.minX - home.x) > 2 || abs(bounds.minY - home.y) > 2

        guard isOnScreen, isDisplaced else {
            // Home again, or off on another Space where there is no desktop to show.
            lastDisplaced = nil
            set(false)
            return
        }
        if let lastDisplaced, abs(lastDisplaced.x - bounds.minX) < 1, abs(lastDisplaced.y - bounds.minY) < 1 {
            set(true)
        }
        lastDisplaced = bounds.origin
    }

    private func set(_ showing: Bool) {
        guard showing != isShowingDesktop else { return }
        isShowingDesktop = showing
        onChange?(showing)
    }
}
