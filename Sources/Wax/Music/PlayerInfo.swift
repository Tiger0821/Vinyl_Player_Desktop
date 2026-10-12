import Foundation

/// What Music says about the current song, from either its broadcast or a scripting query.
struct PlayerInfo: Equatable {
    enum State: Equatable {
        case playing, paused, stopped
    }

    var state: State
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var duration: TimeInterval
    /// Catalogue ids from the broadcast's store link. Absent for local files and scripting queries.
    var storeTrackID: String?
    var storeAlbumID: String?
}

extension PlayerInfo {
    /// Parses the `userInfo` of Music's `com.apple.Music.playerInfo` broadcast.
    init?(userInfo: [AnyHashable: Any]) {
        guard let rawState = userInfo["Player State"] as? String else { return nil }

        func string(_ key: String) -> String {
            (userInfo[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        switch rawState.lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        default: state = .stopped
        }

        title = string("Name")
        artist = string("Artist")
        album = string("Album")
        albumArtist = string("Album Artist")
        duration = ((userInfo["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000

        // Always a signed decimal, whichever form Music sends, so ids compare across sources.
        if let number = userInfo["PersistentID"] as? NSNumber {
            trackID = String(number.int64Value)
        } else if let text = userInfo["PersistentID"] as? String, !text.isEmpty {
            trackID = UInt64(text).map { String(Int64(bitPattern: $0)) } ?? text
        } else {
            trackID = "\(title)|\(artist)|\(album)"
        }

        let storeItems = (userInfo["Store URL"] as? String).flatMap { URLComponents(string: $0)?.queryItems } ?? []
        storeTrackID = storeItems.first { $0.name == "i" }?.value
        storeAlbumID = storeItems.first { $0.name == "p" }?.value
    }
}

/// The current song plus enough timing to work out where the needle is at any moment.
struct Track: Equatable {
    var info: PlayerInfo
    /// Playback position at `anchorDate`.
    var anchorPosition: TimeInterval
    var anchorDate: Date

    var id: String { info.trackID }
    var isPlaying: Bool { info.state == .playing }

    func position(at date: Date) -> TimeInterval {
        let elapsed = isPlaying ? date.timeIntervalSince(anchorDate) : 0
        let position = max(0, anchorPosition + elapsed)
        return info.duration > 0 ? min(position, info.duration) : position
    }

    /// 0 at the lead-in groove, 1 at the run-out. 0 when the length is unknown (radio, streams).
    func progress(at date: Date) -> Double {
        guard info.duration > 0 else { return 0 }
        return position(at: date) / info.duration
    }

    /// Songs from one album share artwork, so they share a key.
    var artworkKey: String {
        guard !info.album.isEmpty else { return "track:\(id)" }
        let owner = info.albumArtist.isEmpty ? info.artist : info.albumArtist
        return "album:\(info.album)|\(owner)".lowercased()
    }
}
