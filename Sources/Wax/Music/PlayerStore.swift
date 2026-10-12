import AppKit
import Combine

/// The single source of truth for what the scene shows: the current track, its artwork and colours.
@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette = Palette.idle
    /// Bumps whenever the displayed artwork changes; drives the sleeve cross-fade.
    @Published private(set) var artworkRevision = 0
    /// True while a transport command is on its way to Music.
    @Published private(set) var isSendingCommand = false
    /// Why the last transport command didn't work, if it didn't.
    @Published private(set) var controlNotice: String?

    /// Called when a song that was really listened to gives way: the song, and its cover if known.
    var onSongFinished: ((Track, NSImage?) -> Void)?

    private let monitor = MusicMonitor()
    private let artworkService = ArtworkService()
    private let scriptingEnabled: Bool
    /// Set once macOS reports that the user refused Wax permission to control Music.
    private var permissionDeclined = false
    private var allowsScripting: Bool { scriptingEnabled && !permissionDeclined }
    private var isSyncing = false

    private var artworkTask: Task<Void, Never>?
    private var shownArtworkKey: String?
    private var pendingArtworkKey: String?
    /// Whether the cover on show was looked up with a catalogue id, i.e. is known to be exact.
    private var shownArtworkIsExact = false
    private var artworkCache: [String: (image: NSImage, isExact: Bool)] = [:]
    private var artworkCacheOrder: [String] = []

    init(allowsScripting: Bool = true) {
        scriptingEnabled = allowsScripting
    }

    func start() {
        monitor.onPlayerInfo = { [weak self] userInfo in self?.ingest(userInfo) }
        monitor.onMusicQuit = { [weak self] in self?.clear() }
        monitor.start()
        syncWithMusic()
    }

    /// Handles one playback broadcast from Music.
    func ingest(_ userInfo: [AnyHashable: Any]) {
        guard let info = PlayerInfo(userInfo: userInfo) else { return }
        Log.debug("broadcast: \(info.state) “\(info.title)” — \(info.artist) [store id: \(info.storeTrackID ?? "none")]")
        apply(info, position: nil)
        syncWithMusic()
    }

    // MARK: - Track state

    private func apply(_ info: PlayerInfo, position: TimeInterval?) {
        guard info.state != .stopped else {
            clear()
            return
        }

        let now = Date()
        var next = Track(info: info, anchorPosition: 0, anchorDate: now)

        if let current = track, current.id == next.id {
            // The broadcast carries no position, so carry our own running clock across play and pause.
            let carried = current.position(at: now)
            let finished = info.duration > 0 && carried >= info.duration - 1.5
            next.anchorPosition = finished ? 0 : carried
            // A scripting reply has no catalogue ids; don't let it erase ones a broadcast supplied.
            next.info.storeTrackID = info.storeTrackID ?? current.info.storeTrackID
            next.info.storeAlbumID = info.storeAlbumID ?? current.info.storeAlbumID
        }
        if let position {
            next.anchorPosition = position
        }

        if let current = track, current.id != next.id {
            noteFinished(current, at: now)
        }
        track = next
        loadArtworkIfNeeded(for: next)
    }

    private func clear() {
        guard track != nil || artwork != nil else { return }
        Log.debug("playback stopped")
        if let current = track {
            noteFinished(current, at: Date())
        }
        artworkTask?.cancel()
        pendingArtworkKey = nil
        shownArtworkKey = nil
        track = nil
        show(nil)
    }

    /// A song counts as played once half of it, or half a minute, has gone by — a skip doesn't.
    private func noteFinished(_ finished: Track, at date: Date) {
        let played = finished.position(at: date)
        let enough = finished.info.duration > 0 ? min(30, finished.info.duration / 2) : 30
        guard played >= enough else {
            Log.debug("skipped “\(finished.info.title)” after \(Int(played))s")
            return
        }
        let cover = shownArtworkKey == finished.artworkKey ? artwork : nil
        onSongFinished?(finished, cover)
    }

    /// Fills in what the broadcast lacks — the song already playing at launch, and the true position.
    private func syncWithMusic() {
        guard allowsScripting, !isSyncing, MusicMonitor.isMusicRunning else { return }
        isSyncing = true

        Task {
            defer { isSyncing = false }

            switch await MusicScripting.currentState() {
            case .success(let reading?):
                if track == nil || track?.id == reading.info.trackID {
                    Log.debug("scripting: position \(Int(reading.position))s of “\(reading.info.title)”")
                    apply(reading.info, position: reading.position)
                }
            case .success(nil):
                break
            case .failure(.notPermitted):
                Log.debug("scripting: permission declined — using broadcasts only")
                permissionDeclined = true
            case .failure(.failed(let message)):
                Log.debug("scripting: \(message)")
            }
        }
    }

    // MARK: - Transport

    /// Play, pause or skip. Music announces the result itself, which is what settles the display.
    func send(_ command: MusicScripting.Command) {
        guard !isSendingCommand else { return }
        isSendingCommand = true

        // Asking Music takes a moment. Play and pause show at once and are confirmed after.
        if command == .playPause, var current = track {
            let now = Date()
            current.anchorPosition = current.position(at: now)
            current.anchorDate = now
            current.info.state = current.isPlaying ? .paused : .playing
            track = current
        }

        Task {
            defer { isSendingCommand = false }
            report(await MusicScripting.send(command), doing: command.rawValue)
        }
    }

    /// Jumps to a point in the current song, in seconds.
    func seek(to seconds: TimeInterval) {
        guard var current = track, current.info.duration > 0 else { return }
        // Stopping just short of the end keeps a drag to the far right from skipping the song.
        let target = min(max(0, seconds), max(0, current.info.duration - 1))
        current.anchorPosition = target
        current.anchorDate = Date()
        track = current

        Task {
            report(await MusicScripting.seek(to: target), doing: "seek")
        }
    }

    /// Says why a command didn't work, and puts the display back in step with Music.
    private func report(_ result: Result<Void, MusicScripting.Failure>, doing what: String) {
        switch result {
        case .success:
            controlNotice = nil
            permissionDeclined = false
            return
        case .failure(.notPermitted):
            permissionDeclined = true
            controlNotice = "Wax isn't allowed to control Music. Allow it in System Settings › Privacy & Security › Automation."
        case .failure(.failed(let message)):
            Log.debug("scripting: \(what) failed — \(message)")
            controlNotice = "Music didn't respond."
        }
        syncWithMusic()
    }

    // MARK: - Artwork

    private func loadArtworkIfNeeded(for track: Track) {
        let key = track.artworkKey
        let storeID = track.info.storeTrackID ?? track.info.storeAlbumID

        if key == pendingArtworkKey { return }
        if key == shownArtworkKey {
            // Settled, unless the earlier attempt was a guess and an exact id has since turned up.
            if shownArtworkIsExact || storeID == nil { return }
        }

        if shownArtworkKey != key, let cached = artworkCache[key] {
            artworkTask?.cancel()
            pendingArtworkKey = nil
            shownArtworkKey = key
            shownArtworkIsExact = cached.isExact
            show(cached.image)
            return
        }

        artworkTask?.cancel()
        pendingArtworkKey = key
        // The previous cover stays up while the next one loads.
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolveArtwork(for: track, storeID: storeID)
            guard !Task.isCancelled, self.track?.artworkKey == key else { return }

            self.pendingArtworkKey = nil
            let alreadyShowingThisAlbum = self.shownArtworkKey == key && self.artwork != nil
            self.shownArtworkKey = key
            self.shownArtworkIsExact = resolved?.isExact ?? (storeID != nil)

            if let resolved {
                self.remember(resolved, for: key)
                self.show(resolved.image)
            } else if !alreadyShowingThisAlbum {
                self.show(nil)
            }
        }
    }

    private func resolveArtwork(for track: Track, storeID: String?) async -> (image: NSImage, isExact: Bool)? {
        if let storeID, let image = await artworkService.artwork(storeID: storeID) {
            Log.debug("artwork: catalogue id \(storeID)")
            return (image, true)
        }
        if allowsScripting, MusicMonitor.isMusicRunning, self.track?.id == track.id,
           let image = await MusicScripting.currentArtwork(), self.track?.id == track.id {
            Log.debug("artwork: from Music")
            return (image, true)
        }
        let info = track.info
        if let image = await artworkService.artwork(title: info.title, artist: info.artist, album: info.album) {
            Log.debug("artwork: matched by name")
            return (image, false)
        }
        Log.debug("artwork: none found for “\(info.title)”")
        return nil
    }

    private func show(_ image: NSImage?) {
        guard image !== artwork else { return }
        artwork = image
        palette = image.map(Palette.init(image:)) ?? .idle
        artworkRevision += 1
    }

    private func remember(_ entry: (image: NSImage, isExact: Bool), for key: String) {
        if artworkCache[key] == nil { artworkCacheOrder.append(key) }
        artworkCache[key] = entry
        if artworkCacheOrder.count > 24 {
            artworkCache[artworkCacheOrder.removeFirst()] = nil
        }
    }

    // MARK: - Development

    /// Feeds one broadcast through the normal path and waits for its artwork to settle.
    func ingestAndWait(_ userInfo: [AnyHashable: Any]) async {
        ingest(userInfo)
        await artworkTask?.value
    }

    func debugSetProgress(_ progress: Double) {
        guard var current = track else { return }
        current.anchorPosition = current.info.duration * min(max(progress, 0), 1)
        current.anchorDate = Date()
        track = current
    }
}
