import AppKit

/// Listens for the playback broadcasts Music posts on this Mac. Needs no permission.
@MainActor
final class MusicMonitor {
    nonisolated static let musicBundleID = "com.apple.Music"

    var onPlayerInfo: (([AnyHashable: Any]) -> Void)?
    var onMusicQuit: (() -> Void)?

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).isEmpty
    }

    func start() {
        guard observers.isEmpty else { return }

        // The override lets a test post fake broadcasts without disturbing other listeners.
        let name = ProcessInfo.processInfo.environment["WAX_NOTIFICATION_NAME"] ?? "com.apple.Music.playerInfo"
        let distributed = DistributedNotificationCenter.default()
        let playerToken = distributed.addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let userInfo = notification.userInfo ?? [:]
            MainActor.assumeIsolated {
                self?.onPlayerInfo?(userInfo)
            }
        }
        observers.append((distributed, playerToken))

        let workspace = NSWorkspace.shared.notificationCenter
        let quitToken = workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.musicBundleID else { return }
            MainActor.assumeIsolated {
                self?.onMusicQuit?()
            }
        }
        observers.append((workspace, quitToken))
    }
}
