import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private var settings: Settings!
    private var store: PlayerStore!
    private var desk: DeskStore!
    private var windows: DesktopWindowController!
    private var mainWindow: MainWindowController!
    private var wallpaper: WallpaperMatcher!
    private var statusItem: NSStatusItem!
    private var openRequestObserver: NSObjectProtocol?

    /// Posted by a second copy of Wax as it bows out, so the running copy shows its window.
    private static let openRequest = Notification.Name("com.tigercho.wax.open")

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would stack a second turntable on the desktop. Hand over and leave.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0 != NSRunningApplication.current }) {
            DistributedNotificationCenter.default().postNotificationName(
                Self.openRequest, object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        settings = Settings()
        store = PlayerStore(allowsScripting: options.allowsScripting)
        // A desk filled for a test is never written over the real one.
        desk = DeskStore(persists: options.deskRecords == nil)
        store.onSongFinished = { [weak self] track, cover in
            Log.debug("finished “\(track.info.title)” — onto the pile")
            self?.desk.put(title: track.info.title, artist: track.info.artist, artwork: cover)
        }
        windows = DesktopWindowController(store: store, settings: settings, desk: desk)
        mainWindow = MainWindowController(store: store, settings: settings, desk: desk)
        wallpaper = WallpaperMatcher(settings: settings)
        installMainMenu()
        installStatusItem()
        store.start()

        openRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.openRequest, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mainWindow.show()
            }
        }

        if let url = options.payloadURL, let payload = DevTools.loadPayload(url) {
            store.ingest(payload)
        }
        if let progress = options.progress {
            store.debugSetProgress(progress)
        }
        if let records = options.deskRecords {
            desk.debugFill(records, covers: DevTools.testCovers())
        }
        if let count = options.celebrates {
            desk.debugCelebrate(count)
        }

        // Opened by hand, show the window. Started at login, stay out of the way.
        if !options.startsInBackground, !wasLaunchedAtLogin {
            mainWindow.show()
        }
    }

    /// Clicking the Dock icon, or opening the app again while it is running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.show()
        return false
    }

    private var wasLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: - Main menu

    /// Shown while the window is open; it is what makes ⌘W, ⌘M, ⌘H and ⌘Q work.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Wax", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Wax", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Wax", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Wax")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        menuNeedsUpdate(menu)
        Log.debug("menu bar item \(statusItem.isVisible ? "installed" : "hidden"): \(menu.items.filter { !$0.isSeparatorItem }.map(\.title))")
    }

    /// Rebuilt each time it opens, so it always reflects the current song and settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let nowPlaying = NSMenuItem(title: nowPlayingTitle, action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        menu.addItem(nowPlaying)
        menu.addItem(item("Open Wax", #selector(openMainWindow), isOn: false))
        menu.addItem(.separator())

        menu.addItem(item("Show on Desktop", #selector(toggleScene), isOn: settings.isSceneVisible))
        menu.addItem(item("Show Song Title", #selector(toggleTrackInfo), isOn: settings.showsTrackInfo))
        menu.addItem(item("Cover Widgets and Desktop Icons", #selector(toggleCoversDesktopItems), isOn: settings.coversDesktopItems))
        menu.addItem(item("Match the Mac's Wallpaper", #selector(toggleMatchesMacWallpaper), isOn: settings.matchesMacWallpaper))

        let scene = NSMenu()
        for option in SceneKind.allCases {
            scene.addItem(item(option.title, #selector(chooseScene(_:)), isOn: settings.scene == option, value: option.rawValue))
        }
        menu.addItem(submenu("Scene", scene))

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin), isOn: settings.opensAtLogin))
        menu.addItem(.separator())
        let pile = NSMenuItem(title: deskTitle, action: nil, keyEquivalent: "")
        pile.isEnabled = false
        menu.addItem(pile)
        let clear = item("Clear the Desk…", #selector(confirmClearDesk), isOn: false)
        clear.isEnabled = desk.count > 0
        menu.addItem(clear)
        menu.addItem(.separator())
        let reset = item("Reset to Factory Settings…", #selector(confirmFactoryReset), isOn: false)
        reset.isEnabled = !settings.isAtFactorySettings
        menu.addItem(reset)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Wax", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private var nowPlayingTitle: String {
        guard let track = store.track else { return "Nothing playing" }
        let line = [track.info.title, track.info.artist].filter { !$0.isEmpty }.joined(separator: " — ")
        let prefix = track.isPlaying ? "♪ " : "Paused: "
        return prefix + (line.count > 56 ? line.prefix(55) + "…" : line)
    }

    private var deskTitle: String {
        switch desk.count {
        case 0: "The desk is clear"
        case 1: "1 record on the desk"
        default: "\(desk.count) records on the desk"
        }
    }

    private func item(_ title: String, _ action: Selector, isOn: Bool, value: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        item.representedObject = value
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - Actions

    @objc private func openMainWindow() {
        mainWindow.show()
    }

    @objc private func toggleScene() {
        settings.isSceneVisible.toggle()
    }

    @objc private func toggleTrackInfo() {
        settings.showsTrackInfo.toggle()
    }

    @objc private func toggleCoversDesktopItems() {
        settings.coversDesktopItems.toggle()
    }

    @objc private func toggleMatchesMacWallpaper() {
        settings.matchesMacWallpaper.toggle()
    }

    @objc private func chooseScene(_ sender: NSMenuItem) {
        guard let scene = (sender.representedObject as? String).flatMap(SceneKind.init(rawValue:)) else { return }
        settings.scene = scene
    }

    @objc private func confirmClearDesk() {
        let alert = NSAlert()
        alert.messageText = "Clear the desk?"
        alert.informativeText = "The pile of records goes back to none. Medals you've earned stay."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            desk.clear()
        }
    }

    @objc private func confirmFactoryReset() {
        let alert = NSAlert()
        alert.messageText = "Reset Wax to its factory settings?"
        alert.informativeText = "The turntable goes back to how it looked when Wax was first installed, and Wax stops opening at login."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            settings.resetToFactorySettings()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try settings.setOpensAtLogin(!settings.opensAtLogin)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMoving Wax into the Applications folder usually fixes this."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
