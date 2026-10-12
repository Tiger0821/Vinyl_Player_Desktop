import AppKit
import SwiftUI

/// Development helpers reached through command-line switches: render the scene to a PNG,
/// render the app icon, and check which way the record turns.
@MainActor
enum DevTools {
    static func run(_ options: LaunchOptions) async -> Int32 {
        if options.runsSelfTest { return max(spinSelfTest(), resetSelfTest()) }
        if let url = options.iconURL { return write(render(AppIconArt(), scale: 1), to: url) }
        if let url = options.snapshotURL { return await snapshot(options, to: url) }
        if let url = options.windowSnapshotURL { return await windowSnapshot(options, to: url) }
        if let url = options.wallpaperURL {
            // Writes the picture only; nothing here touches the Mac's wallpaper setting.
            guard let picture = SceneWallpaper.picture(for: options.scene ?? .listeningRoom),
                  SceneWallpaper.write(picture, to: url)
            else { return 1 }
            print("wrote \(url.path) (\(picture.width)×\(picture.height))")
            return 0
        }
        return 0
    }

    /// A JSON object with the same keys as Music's broadcast.
    static func loadPayload(_ url: URL) -> [AnyHashable: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data("wax: couldn't read payload at \(url.path)\n".utf8))
            return nil
        }
        return object
    }

    // MARK: - Snapshot

    /// Throwaway state built from the command line, shared by both kinds of snapshot.
    private static func stage(_ options: LaunchOptions) async -> (store: PlayerStore, settings: Settings, desk: DeskStore)? {
        let settings = Settings(defaults: nil)
        if let scene = options.scene { settings.scene = scene }

        let store = PlayerStore(allowsScripting: false)
        if let payloadURL = options.payloadURL {
            guard let payload = loadPayload(payloadURL) else { return nil }
            await store.ingestAndWait(payload)
        }
        if let progress = options.progress { store.debugSetProgress(progress) }

        let desk = DeskStore(persists: false)
        if let records = options.deskRecords { desk.debugFill(records, covers: testCovers()) }
        if let count = options.celebrates { desk.debugCelebrate(count) }
        return (store, settings, desk)
    }

    /// A handful of differently coloured covers, so a test pile doesn't look like one record.
    static func testCovers() -> [NSImage] {
        let hues: [Double] = [0.02, 0.58, 0.12, 0.78, 0.36, 0.95, 0.5]
        return hues.map { hue in
            let cover = ZStack {
                LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.6, brightness: 0.85), Color(hue: hue + 0.06, saturation: 0.75, brightness: 0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Circle().strokeBorder(.white.opacity(0.5), lineWidth: 10).padding(90)
                Circle().fill(.white.opacity(0.85)).frame(width: 90, height: 90)
            }
            .frame(width: 480, height: 480)
            let renderer = ImageRenderer(content: cover)
            return renderer.nsImage ?? NSImage(size: NSSize(width: 480, height: 480))
        }
    }

    private static func windowSnapshot(_ options: LaunchOptions, to url: URL) async -> Int32 {
        guard let (store, settings, desk) = await stage(options) else { return 1 }
        let window = MainWindowView(isStaticRender: true)
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(desk)
        return write(render(window, scale: 2), to: url)
    }

    private static func snapshot(_ options: LaunchOptions, to url: URL) async -> Int32 {
        guard let (store, settings, desk) = await stage(options) else { return 1 }

        // A still shows the bare photograph with the words over it; the records are live layers.
        let scene = SceneRootView(isStaticRender: true)
            .frame(width: 1512, height: 982)
        .environmentObject(store)
        .environmentObject(settings)
        .environmentObject(desk)

        return write(render(scene, scale: 2), to: url)
    }

    private static func render(_ view: some View, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    private static func write(_ image: CGImage?, to url: URL) -> Int32 {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("wax: rendering failed\n".utf8))
            return 1
        }
        do {
            try data.write(to: url)
            print("wrote \(url.path) (\(image.width)×\(image.height))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("wax: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: - Self test

    /// Confirms the label turns clockwise on screen. The sign of a layer rotation depends on
    /// whether an ancestor flips its coordinates, so this measures it in a real window.
    private static func spinSelfTest() -> Int32 {
        let frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(
            rootView: SpinningDisc(image: DefaultLabelArt.image, isSpinning: false).frame(width: 200, height: 200)
        )
        host.frame = frame
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let view = firstDisc(in: host) else {
            print("selftest: disc view not found")
            return 1
        }
        view.layoutSubtreeIfNeeded()

        func inWindow(_ point: CGPoint) -> CGPoint {
            view.convert(view.convertFromLayer(view.disc.convert(point, to: view.layer)), to: nil)
        }

        let bounds = view.disc.bounds
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let probe = CGPoint(x: bounds.midX + 50, y: bounds.midY)

        let origin = inWindow(centre)
        let before = inWindow(probe)
        view.disc.setValue(-0.4, forKeyPath: "transform.rotation.z")
        let after = inWindow(probe)

        // Window coordinates run upwards, where a negative cross product is a clockwise turn.
        let cross = (before.x - origin.x) * (after.y - origin.y) - (before.y - origin.y) * (after.x - origin.x)
        let isClockwise = cross < 0
        print("selftest: a negative layer angle turns the label \(isClockwise ? "clockwise" : "ANTICLOCKWISE")")
        return isClockwise ? 0 : 1
    }

    /// Confirms a factory reset undoes every setting. Uses a throwaway instance, so the
    /// user's real preferences and login item are never touched.
    private static func resetSelfTest() -> Int32 {
        let settings = Settings(defaults: nil)
        let startsClean = settings.isAtFactorySettings

        settings.scene = .turntable
        settings.isSceneVisible.toggle()
        settings.showsTrackInfo.toggle()
        settings.coversDesktopItems.toggle()
        settings.matchesMacWallpaper.toggle()
        let noticesChanges = !settings.isAtFactorySettings

        settings.resetToFactorySettings()
        let passed = startsClean && noticesChanges && settings.isAtFactorySettings
        print("selftest: factory reset \(passed ? "restores every setting" : "FAILED")")
        return passed ? 0 : 1
    }

    private static func firstDisc(in view: NSView) -> SpinningDiscView? {
        if let disc = view as? SpinningDiscView { return disc }
        for subview in view.subviews {
            if let disc = firstDisc(in: subview) { return disc }
        }
        return nil
    }
}

/// The app icon: the record on its walnut plinth.
private struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.5, green: 0.31, blue: 0.17),
                        Color(red: 0.3, green: 0.17, blue: 0.09),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

            ZStack {
                Circle().fill(Color(white: 0.05))
                ForEach(0..<13, id: \.self) { ring in
                    Circle()
                        .strokeBorder(.white.opacity(0.08), lineWidth: 2)
                        .padding(CGFloat(16 + ring * 15))
                }
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.03),
                            .init(color: .white.opacity(0.22), location: 0.125),
                            .init(color: .clear, location: 0.22),
                            .init(color: .clear, location: 0.53),
                            .init(color: .white.opacity(0.3), location: 0.625),
                            .init(color: .clear, location: 0.72),
                        ]),
                        center: .center
                    ))
                    .blendMode(.screen)
                Image(nsImage: DefaultLabelArt.image)
                    .resizable()
                    .frame(width: 236, height: 236)
                Circle()
                    .fill(Color(white: 0.88))
                    .frame(width: 22, height: 22)
            }
            .frame(width: 650, height: 650)
            .shadow(color: .black.opacity(0.5), radius: 16, x: 6, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }
}
