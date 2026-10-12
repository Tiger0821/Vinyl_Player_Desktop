import SwiftUI

/// Stands in when a song has no cover, and introduces the app when nothing is playing.
struct PlaceholderCover: View {
    /// Nil when nothing is playing, which makes it the app's own cover.
    let title: String?
    let artist: String?
    let unit: CGFloat

    init(title: String?, artist: String?, unit: CGFloat) {
        self.title = title
        self.artist = artist
        self.unit = unit
    }

    init(track: Track?, unit: CGFloat) {
        self.init(title: track?.info.title, artist: track?.info.artist, unit: unit)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.88, green: 0.42, blue: 0.18),
                        Color(red: 0.55, green: 0.17, blue: 0.15),
                        Color(red: 0.2, green: 0.08, blue: 0.13),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                ForEach(0..<8, id: \.self) { ring in
                    let diameter = (150 + CGFloat(ring) * 92) * unit
                    Circle()
                        .strokeBorder(.white.opacity(0.11), lineWidth: 1.5 * unit)
                        .frame(width: diameter, height: diameter)
                        .position(x: proxy.size.width * 0.92, y: proxy.size.height * 0.94)
                }

                VStack(alignment: .leading, spacing: 8 * unit) {
                    Text(title ?? "Wax")
                        .font(.system(size: (title == nil ? 64 : 42) * unit, weight: .bold, design: .serif))
                        .lineLimit(3)
                    Text(title == nil ? "Play something in Music\nto drop the needle." : artist ?? "")
                        .font(.system(size: 20 * unit, weight: .medium))
                        .opacity(0.8)
                        .lineLimit(2)
                }
                .foregroundStyle(Color(red: 1.0, green: 0.93, blue: 0.82))
                .padding(34 * unit)
            }
        }
    }
}

struct TrackInfoView: View {
    let track: Track
    let unit: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * unit) {
            Text(track.info.title)
                .font(.system(size: 29 * unit, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.94))
            Text(subtitle)
                .font(.system(size: 18 * unit, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))
        }
        .lineLimit(1)
        // Keeps the words legible over a bright wallpaper when the backdrop is off.
        .shadow(color: .black.opacity(0.55), radius: 5 * unit, y: 2 * unit)
    }

    private var subtitle: String {
        [track.info.artist, track.info.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}
