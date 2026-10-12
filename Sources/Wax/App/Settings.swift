import Combine
import Foundation
import ServiceManagement

/// What the desktop shows. Each is a rendered photograph the listener's records are painted into.
enum SceneKind: String, CaseIterable {
    case listeningRoom, afterHours, turntable

    var title: String {
        switch self {
        case .listeningRoom: "Listening Room"
        case .afterHours: "After Hours"
        case .turntable: "Turntable"
        }
    }

    /// The base name of the scene's pictures in the app's Scenes folder.
    var assetName: String {
        switch self {
        case .listeningRoom: "listening-room"
        case .afterHours: "after-hours"
        case .turntable: "turntable"
        }
    }

    /// The base name of the files describing the scene's camera and surfaces. The two rooms
    /// are one room in different light, so they share a description.
    var layoutName: String {
        self == .turntable ? "turntable" : "room"
    }
}

/// User preferences. Pass `defaults: nil` for a throwaway instance that persists nothing.
final class Settings: ObservableObject {
    private enum Key {
        static let visible = "sceneVisible"
        static let trackInfo = "showsTrackInfo"
        static let coversDesktopItems = "coversDesktopItems"
        static let scene = "scene"
        static let matchesMacWallpaper = "matchesMacWallpaper"
    }

    /// What a fresh install starts with, and what a factory reset goes back to.
    private enum Factory {
        static let scene = SceneKind.listeningRoom
        static let isSceneVisible = true
        static let showsTrackInfo = true
        static let coversDesktopItems = true
        static let matchesMacWallpaper = true
    }

    private let defaults: UserDefaults?

    @Published var scene: SceneKind { didSet { defaults?.set(scene.rawValue, forKey: Key.scene) } }
    @Published var isSceneVisible: Bool { didSet { defaults?.set(isSceneVisible, forKey: Key.visible) } }
    @Published var showsTrackInfo: Bool { didSet { defaults?.set(showsTrackInfo, forKey: Key.trackInfo) } }
    /// Whether the scene sits in front of desktop widgets and icons, or behind them.
    @Published var coversDesktopItems: Bool { didSet { defaults?.set(coversDesktopItems, forKey: Key.coversDesktopItems) } }
    /// Whether the Mac's own wallpaper is kept the same picture as the scene, so the menu
    /// bar and anything else macOS draws from the wallpaper shows the scene too.
    @Published var matchesMacWallpaper: Bool { didSet { defaults?.set(matchesMacWallpaper, forKey: Key.matchesMacWallpaper) } }
    /// Mirrors the system's login item for Wax, which is the real record. Change it with `setOpensAtLogin`.
    @Published private(set) var opensAtLogin: Bool

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        scene = defaults?.string(forKey: Key.scene).flatMap(SceneKind.init(rawValue:)) ?? Factory.scene
        isSceneVisible = defaults?.object(forKey: Key.visible) as? Bool ?? Factory.isSceneVisible
        showsTrackInfo = defaults?.object(forKey: Key.trackInfo) as? Bool ?? Factory.showsTrackInfo
        coversDesktopItems = defaults?.object(forKey: Key.coversDesktopItems) as? Bool ?? Factory.coversDesktopItems
        matchesMacWallpaper = defaults?.object(forKey: Key.matchesMacWallpaper) as? Bool ?? Factory.matchesMacWallpaper
        opensAtLogin = defaults != nil && SMAppService.mainApp.status == .enabled
    }

    func setOpensAtLogin(_ enabled: Bool) throws {
        // A throwaway instance must not touch the real login item.
        guard defaults != nil else { return }
        defer { opensAtLogin = SMAppService.mainApp.status == .enabled }

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    var isAtFactorySettings: Bool {
        scene == Factory.scene
            && isSceneVisible == Factory.isSceneVisible
            && showsTrackInfo == Factory.showsTrackInfo
            && coversDesktopItems == Factory.coversDesktopItems
            && matchesMacWallpaper == Factory.matchesMacWallpaper
            && !opensAtLogin
    }

    /// Puts every setting back the way a fresh install has it, including not opening at login.
    func resetToFactorySettings() {
        scene = Factory.scene
        isSceneVisible = Factory.isSceneVisible
        showsTrackInfo = Factory.showsTrackInfo
        coversDesktopItems = Factory.coversDesktopItems
        matchesMacWallpaper = Factory.matchesMacWallpaper
        if opensAtLogin {
            try? setOpensAtLogin(false)
        }
    }
}
