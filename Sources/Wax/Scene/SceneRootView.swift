import SwiftUI

/// What fills the desktop: the chosen scene with the listener's records painted in, the
/// song's name set over it, and a cheer when a milestone is reached.
struct SceneRootView: View {
    @EnvironmentObject private var store: PlayerStore
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var desk: DeskStore
    /// True when drawing a still image, where live layers are unavailable.
    var isStaticRender = false
    /// Shows this scene whatever the setting says; the scene picker's thumbnails use it.
    var forcedScene: SceneKind?
    /// Set for thumbnails, to load reduced photographs.
    var maxPixelWidth: Int?

    var body: some View {
        let kind = forcedScene ?? settings.scene

        GeometryReader { proxy in
            let unit = proxy.size.width / 1512

            ZStack(alignment: .bottomLeading) {
                if isStaticRender {
                    // A still can't host live layers, so it shows the bare photograph.
                    if let plate = RoomAssets.load(kind, maxPixelWidth: maxPixelWidth ?? 1512)?.plate {
                        FilledImage(image: NSImage(cgImage: plate, size: .zero))
                    }
                } else {
                    RoomSceneLayerView(
                        kind: kind,
                        artwork: store.artwork,
                        track: store.track,
                        pile: desk.records,
                        cover: { [desk] in desk.cover(for: $0) },
                        maxPixelWidth: maxPixelWidth
                    )
                }

                if settings.showsTrackInfo, let track = store.track {
                    TrackInfoView(track: track, unit: unit)
                        .frame(width: 620 * unit, alignment: .leading)
                        .padding(.leading, 64 * unit)
                        .padding(.bottom, 118 * unit)
                }

                // Thumbnails of the scene stay quiet; only the desktop itself cheers.
                // It appears top-right, where notifications do, clear of the pile it's about.
                if forcedScene == nil, let milestone = desk.celebration {
                    CelebrationToast(milestone: milestone, unit: unit)
                        .padding(.trailing, 44 * unit)
                        .padding(.top, 76 * unit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.spring(duration: 0.7, bounce: 0.28), value: desk.celebration)
        }
        .ignoresSafeArea()
    }
}
