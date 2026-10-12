import AppKit

/// Asks Music directly, over Apple Events, for the things its broadcast leaves out:
/// what is playing when Wax starts, the playback position, and artwork for local files.
///
/// macOS asks the user for permission the first time. Everything here is optional — when
/// permission is refused the app carries on with the broadcast alone.
enum MusicScripting {
    struct Reading {
        var info: PlayerInfo
        var position: TimeInterval
    }

    enum Failure: Error {
        case notPermitted
        case failed(String)
    }

    /// The transport buttons, spelled the way Music's scripting dictionary spells them.
    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        /// Restarts the song, or steps back a song when it has only just begun.
        case previous = "back track"
    }

    private static let separator = "\u{1F}"

    private static let stateScript = """
    tell application "Music"
    	if player state is stopped then return "stopped"
    	set sep to character id 31
    	set theState to "paused"
    	if player state is playing then set theState to "playing"
    	set thePosition to 0
    	try
    		set thePosition to player position
    	end try
    	set t to current track
    	set theDuration to 0
    	try
    		set theDuration to duration of t
    	end try
    	return theState & sep & (thePosition as text) & sep & (persistent ID of t) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (album artist of t) & sep & (theDuration as text)
    end tell
    """

    /// `nil` on success means Music is open but stopped.
    static func currentState() async -> Result<Reading?, Failure> {
        let output = await run(stateScript)
        guard output.status == 0 else { return .failure(failure(from: output.error)) }

        let text = output.text.trimmingCharacters(in: .newlines)
        guard text != "stopped" else { return .success(nil) }

        let fields = text.components(separatedBy: separator)
        guard fields.count == 8 else { return .failure(.failed("unexpected reply: \(text)")) }

        // Scripting reports the id in hex; the broadcast reports the same id as a signed decimal.
        let trackID = UInt64(fields[2], radix: 16).map { String(Int64(bitPattern: $0)) } ?? fields[2]
        let info = PlayerInfo(
            state: fields[0] == "playing" ? .playing : .paused,
            trackID: trackID,
            title: fields[3],
            artist: fields[4],
            album: fields[5],
            albumArtist: fields[6],
            duration: number(fields[7]),
            storeTrackID: nil,
            storeAlbumID: nil
        )
        return .success(Reading(info: info, position: number(fields[1])))
    }

    static func send(_ command: Command) async -> Result<Void, Failure> {
        let output = await run("tell application \"Music\" to \(command.rawValue)")
        return output.status == 0 ? .success(()) : .failure(failure(from: output.error))
    }

    /// Moves playback to a point in the current song, in seconds.
    static func seek(to seconds: TimeInterval) async -> Result<Void, Failure> {
        let output = await run("tell application \"Music\" to set player position to \(max(0, seconds))")
        return output.status == 0 ? .success(()) : .failure(failure(from: output.error))
    }

    /// The current track's own artwork, when it has any (library and local files usually do).
    static func currentArtwork() async -> NSImage? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wax-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        let path = file.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
        	set artData to raw data of artwork 1 of current track
        end tell
        set outFile to open for access (POSIX file "\(path)") with write permission
        set eof outFile to 0
        write artData to outFile
        close access outFile
        """

        let output = await run(script)
        guard output.status == 0 else {
            Log.debug("scripting: no artwork (\(output.error.trimmingCharacters(in: .whitespacesAndNewlines)))")
            return nil
        }
        return NSImage(contentsOf: file)
    }

    // MARK: - Running scripts

    /// AppleScript writes numbers in the user's locale, so "83,5" is as likely as "83.5".
    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func failure(from error: String) -> Failure {
        // -1743 is errAEEventNotPermitted: the user declined the automation prompt.
        error.contains("-1743") ? .notPermitted : .failed(error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs out of process so a pending permission prompt never blocks the main thread.
    private static func run(_ source: String) async -> (status: Int32, text: String, error: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let outPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errorPipe
            process.terminationHandler = { finished in
                let text = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (finished.terminationStatus, text, error))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: (-1, "", error.localizedDescription))
            }
        }
    }
}
