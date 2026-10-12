import AppKit
import SwiftUI

/// The app's window: what's playing on top, how the desktop turntable looks underneath.
struct MainWindowView: View {
    static let size = CGSize(width: 780, height: 787)

    @EnvironmentObject private var store: PlayerStore
    /// True when drawing a still image, where live layers and timers are unavailable.
    var isStaticRender = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NowPlayingSection(isStaticRender: isStaticRender)
                .padding(.top, 46)

            DeskStrip()
                .padding(.top, 20)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.top, 20)

            DesktopSection(isStaticRender: isStaticRender)
                .padding(.top, 22)

            Spacer(minLength: 0)

            Text("Closing this window leaves Wax running in the menu bar.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.cream.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 32)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(WindowBackdrop(palette: store.palette))
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

/// The same album tint as the desktop, kept dark enough for cream text to read on.
private struct WindowBackdrop: View {
    let palette: Palette

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.mid, palette.deep], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [palette.glow.opacity(0.55), palette.glow.opacity(0)],
                center: UnitPoint(x: 0.16, y: 0.2),
                startRadius: 0,
                endRadius: 460
            )
        }
        .animation(.easeInOut(duration: 0.9), value: palette)
    }
}

// MARK: - Now playing

private struct NowPlayingSection: View {
    @EnvironmentObject private var store: PlayerStore
    let isStaticRender: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            CoverWithRecord(isStaticRender: isStaticRender)

            Group {
                if let track = store.track {
                    TrackPanel(track: track)
                } else {
                    EmptyPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 218)
    }
}

/// The sleeve with its record drawn part-way out — further, and turning, while a song plays.
private struct CoverWithRecord: View {
    @EnvironmentObject private var store: PlayerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isStaticRender: Bool

    private let side: CGFloat = 208
    private let recordDiameter: CGFloat = 192

    var body: some View {
        let isPlaying = store.track?.isPlaying == true
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        ZStack(alignment: .leading) {
            RecordView(
                artwork: store.artwork,
                isSpinning: isPlaying && !reduceMotion,
                // RecordView's details are sized for a 480-point record.
                unit: recordDiameter / 480,
                isStaticRender: isStaticRender
            )
            .frame(width: recordDiameter, height: recordDiameter)
            .offset(x: recordOffset(isPlaying: isPlaying))

            Group {
                if let artwork = store.artwork {
                    FilledImage(image: artwork)
                } else {
                    PlaceholderCover(track: store.track, unit: side / 480)
                }
            }
            .frame(width: side, height: side)
            .overlay(shape.fill(LinearGradient(
                colors: [.white.opacity(0.14), .white.opacity(0), .black.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )))
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.5), radius: 14, x: 4, y: 10)
            .accessibilityHidden(true)
        }
        .frame(width: 344, height: side, alignment: .leading)
        .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.18), value: isPlaying)
        .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.18), value: store.track == nil)
    }

    private func recordOffset(isPlaying: Bool) -> CGFloat {
        if store.track == nil { return 28 }
        return isPlaying ? 148 : 104
    }
}

private struct TrackPanel: View {
    @EnvironmentObject private var store: PlayerStore
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: track.isPlaying ? "Now playing" : "Paused")

            Text(track.info.title)
                .font(.system(size: 27, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.cream)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.top, 8)

            Text(track.info.artist)
                .font(.system(size: 15))
                .foregroundStyle(Theme.cream.opacity(0.8))
                .lineLimit(1)
                .padding(.top, 5)

            Text(track.info.album)
                .font(.system(size: 13))
                .foregroundStyle(Theme.cream.opacity(0.58))
                .lineLimit(1)
                .padding(.top, 2)

            Spacer(minLength: 8)

            if track.info.duration > 0 {
                Scrubber(track: track)
            }

            HStack(spacing: 10) {
                RoundIconButton(symbol: "backward.fill", label: "Previous song") {
                    store.send(.previous)
                }
                RoundIconButton(
                    symbol: track.isPlaying ? "pause.fill" : "play.fill",
                    label: track.isPlaying ? "Pause" : "Play",
                    isProminent: true
                ) {
                    store.send(.playPause)
                }
                .keyboardShortcut(.space, modifiers: [])
                RoundIconButton(symbol: "forward.fill", label: "Next song") {
                    store.send(.next)
                }

                if let notice = store.controlNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ember)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 6)
                }
            }
            .disabled(store.isSendingCommand)
            .padding(.top, 10)
            // Lines the round buttons' glyphs up with the text above them.
            .padding(.leading, -8)
        }
    }
}

/// How far through the song playback is. Drag it, or click anywhere along it, to move there.
private struct Scrubber: View {
    @EnvironmentObject private var store: PlayerStore
    let track: Track

    /// Where the handle is being held, as a fraction of the song, while it is being dragged.
    @State private var held: Double?
    @State private var isHovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let duration = track.info.duration
            let position = held.map { $0 * duration } ?? track.position(at: timeline.date)
            let fraction = min(1, max(0, position / duration))
            let isActive = isHovered || held != nil

            VStack(spacing: 3) {
                GeometryReader { proxy in
                    let width = proxy.size.width

                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.cream.opacity(0.16))
                            .frame(height: isActive ? 6 : 4)
                        Capsule().fill(Theme.cream)
                            .frame(width: max(4, width * fraction), height: isActive ? 6 : 4)
                        Circle().fill(Theme.cream)
                            .frame(width: 13, height: 13)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .offset(x: min(width - 13, max(0, width * fraction - 6.5)))
                            .opacity(isActive ? 1 : 0)
                    }
                    // The bar is thin; the place to grab it is not.
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { held = Self.share($0.location.x, of: width) }
                            .onEnded { value in
                                store.seek(to: Self.share(value.location.x, of: width) * duration)
                                held = nil
                            }
                    )
                }
                .frame(height: 16)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isActive)

                HStack {
                    Text(Self.clock(position))
                    Spacer()
                    Text("-" + Self.clock(duration - position))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.cream.opacity(0.6))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue("\(Self.clock(position)) of \(Self.clock(duration))")
            .accessibilityAdjustableAction { direction in
                let now = track.position(at: Date())
                store.seek(to: direction == .increment ? now + 10 : now - 10)
            }
        }
    }

    /// How far along the bar a point is, from 0 at its left end to 1 at its right.
    private static func share(_ x: CGFloat, of width: CGFloat) -> Double {
        Double(min(1, max(0, x / width)))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct EmptyPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Nothing playing")

            Text("The platter's empty")
                .font(.system(size: 27, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.cream)
                .padding(.top, 8)

            Text("Play a song in Music and it shows up here and on your desktop.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.cream.opacity(0.72))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Spacer(minLength: 8)

            Button("Open Music") {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicMonitor.musicBundleID) else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            .buttonStyle(PillButtonStyle())
        }
    }
}

// MARK: - Desktop settings

private struct DesktopSection: View {
    @EnvironmentObject private var settings: Settings
    let isStaticRender: Bool
    @State private var loginNotice: String?
    @State private var isConfirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "On your desktop")
                Spacer()
                Button {
                    isConfirmingReset = true
                } label: {
                    Label("Reset to factory settings", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(QuietButtonStyle())
                // Its text, not its hover shape, lines up with the controls below.
                .padding(.trailing, -9)
                // Nothing to reset when nothing has been changed.
                .disabled(settings.isAtFactorySettings)
                .confirmationDialog("Reset Wax to its factory settings?", isPresented: $isConfirmingReset) {
                    Button("Reset", role: .destructive) {
                        withAnimation(.snappy(duration: 0.25)) {
                            settings.resetToFactorySettings()
                        }
                        loginNotice = nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The desktop goes back to how it looked when Wax was first installed, and Wax stops opening at login.")
                }
            }

            HStack(spacing: 14) {
                ForEach(SceneKind.allCases, id: \.self) { kind in
                    SceneCard(kind: kind, isSelected: settings.scene == kind, isStaticRender: isStaticRender) {
                        withAnimation(.snappy(duration: 0.22)) {
                            settings.scene = kind
                        }
                    }
                }
            }
            .padding(.bottom, 2)

            HStack(alignment: .top, spacing: 30) {
                VStack(spacing: 5) {
                    toggle("Show on the desktop", isOn: $settings.isSceneVisible)
                    toggle("Song title", isOn: $settings.showsTrackInfo)
                        .dimmed(!settings.isSceneVisible)
                    toggle("Match the Mac's wallpaper", isOn: $settings.matchesMacWallpaper)
                        .help("Makes the scene your Mac's wallpaper too, so the menu bar shows it instead of your own wallpaper. Your own comes back when you turn this off.")
                }
                VStack(spacing: 5) {
                    toggle("Cover widgets and desktop icons", isOn: $settings.coversDesktopItems)
                        .dimmed(!settings.isSceneVisible)
                    toggle("Open Wax at login", isOn: Binding(get: { settings.opensAtLogin }, set: setOpensAtLogin))

                    if let loginNotice {
                        Text(loginNotice)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ember)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: settings.isSceneVisible)
        }
    }

    private func rowTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(Theme.cream.opacity(0.92))
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { rowTitle(title) }
            .toggleStyle(SwitchToggleStyle())
            .frame(height: 30)
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            try settings.setOpensAtLogin(enabled)
            loginNotice = nil
        } catch {
            loginNotice = "Couldn't change this: \(error.localizedDescription)"
        }
    }
}

private extension View {
    /// Greyed out and inert, for settings that don't apply right now.
    func dimmed(_ isDimmed: Bool) -> some View {
        disabled(isDimmed).opacity(isDimmed ? 0.38 : 1)
    }
}

/// One scene to choose: a live picture of it showing the current cover, and its name.
private struct SceneCard: View {
    let kind: SceneKind
    let isSelected: Bool
    let isStaticRender: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)

        Button(action: action) {
            VStack(spacing: 0) {
                SceneRootView(isStaticRender: isStaticRender, forcedScene: kind, maxPixelWidth: 760)
                    .aspectRatio(screen.width / screen.height, contentMode: .fit)
                    .clipped()
                    // The picture is decoration here; clicks belong to the card.
                    .allowsHitTesting(false)

                HStack(spacing: 8) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.cream.opacity(isSelected ? 1 : 0.82))
                    Spacer(minLength: 4)
                    ZStack {
                        Circle()
                            .strokeBorder(Theme.cream.opacity(isSelected ? 0 : 0.4), lineWidth: 1.5)
                        if isSelected {
                            Circle().fill(Theme.cream)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
            }
            .background(Color.white.opacity(isSelected ? 0.1 : 0.05))
            .clipShape(shape)
            .overlay(shape.strokeBorder(
                Theme.cream.opacity(isSelected ? 0.9 : isHovered ? 0.34 : 0.14),
                lineWidth: isSelected ? 1.5 : 1
            ))
            .shadow(color: .black.opacity(isSelected ? 0.4 : 0.22), radius: isSelected ? 12 : 6, y: 5)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
