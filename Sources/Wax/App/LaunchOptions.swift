import Foundation

/// Command-line switches. They exist for development; the app needs none of them.
struct LaunchOptions {
    var verbose = false
    var allowsScripting = true
    /// A JSON file shaped like Music's playback broadcast, fed in as if Music had posted it.
    var payloadURL: URL?
    var snapshotURL: URL?
    var windowSnapshotURL: URL?
    var wallpaperURL: URL?
    /// Start in the menu bar without opening the window.
    var startsInBackground = false
    var iconURL: URL?
    var runsSelfTest = false
    var scene: SceneKind?
    /// Start with this many records already on the desk, kept in memory only.
    var deskRecords: Int?
    /// Celebrate this milestone at launch.
    var celebrates: Int?
    var progress: Double?

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        func nextURL() -> URL? { iterator.next().map { URL(fileURLWithPath: $0) } }

        while let argument = iterator.next() {
            switch argument {
            case "--verbose": verbose = true
            case "--no-scripting": allowsScripting = false
            case "--payload": payloadURL = nextURL()
            case "--snapshot": snapshotURL = nextURL()
            case "--snapshot-window": windowSnapshotURL = nextURL()
            case "--wallpaper": wallpaperURL = nextURL()
            case "--background": startsInBackground = true
            case "--render-icon": iconURL = nextURL()
            case "--selftest": runsSelfTest = true
            case "--scene": scene = iterator.next().flatMap(SceneKind.init(rawValue:))
            case "--desk": deskRecords = iterator.next().flatMap(Int.init)
            case "--celebrate": celebrates = iterator.next().flatMap(Int.init)
            case "--progress": progress = iterator.next().flatMap(Double.init)
            default: break
            }
        }
    }

    var isDevTool: Bool {
        snapshotURL != nil || windowSnapshotURL != nil || wallpaperURL != nil || iconURL != nil || runsSelfTest
    }
}

enum Log {
    static var isVerbose = false

    static func debug(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        FileHandle.standardError.write(Data("[wax] \(message())\n".utf8))
    }
}
