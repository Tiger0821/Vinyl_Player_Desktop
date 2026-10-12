import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// A scene as a finished picture, fit to be the Mac's own wallpaper.
///
/// Wax only covers the Mac's wallpaper; it doesn't replace it. Anything macOS draws from the
/// wallpaper itself — the menu bar's background above all — still shows the old one. The
/// cure is to make the real wallpaper the same picture as the scene.
@MainActor
enum SceneWallpaper {
    /// The scene's photograph with the stand-in cover, label and parked tonearm painted in,
    /// so it looks finished on its own when Wax isn't running in front of it.
    static func picture(for kind: SceneKind) -> CGImage? {
        guard let assets = RoomAssets.load(kind),
              let sleeveArt = DefaultArt.sleeve.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let labelArt = DefaultLabelArt.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let plate = CIImage(cgImage: assets.plate)
        let width = plate.extent.width, height = plate.extent.height
        // Core Image measures upwards from the bottom-left; the layout measures down from the top.
        func place(_ fraction: CGPoint) -> CGPoint {
            CGPoint(x: fraction.x * width, y: (1 - fraction.y) * height)
        }

        /// Bends a picture onto four corners, lights it with the photograph, and keeps it
        /// only where the stencil says the surface shows.
        func painted(_ art: CGImage, corners: [CGPoint], stencil: CIImage, over base: CIImage) -> CIImage {
            let bend = CIFilter.perspectiveTransform()
            bend.inputImage = CIImage(cgImage: art)
            bend.topLeft = place(corners[0])
            bend.topRight = place(corners[1])
            bend.bottomRight = place(corners[2])
            bend.bottomLeft = place(corners[3])
            guard let bent = bend.outputImage else { return base }

            let lit = bent.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: base])
            return lit.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: stencil,
            ])
        }

        var picture = painted(
            sleeveArt, corners: RoomLayout.points(assets.layout.sleeve),
            stencil: CIImage(cgImage: assets.surfaceMask), over: plate
        )

        // The label's stencil covers only its own box, so it has to be slid into place.
        let box = RoomAssets.pixels(assets.labelBox, in: assets.plate)
        let labelStencil = CIImage(cgImage: assets.labelMask)
            .transformed(by: CGAffineTransform(translationX: box.minX, y: height - box.maxY))
        picture = painted(labelArt, corners: RoomLayout.points(assets.layout.label), stencil: labelStencil, over: picture)

        // A cut-out tonearm isn't in the photograph; set it down in its rest, shadow first.
        if let arm = assets.layout.arm, let sprite = assets.armSprite, let shadow = assets.armShadow {
            for (image, bounds, pivot) in [(shadow, arm.shadow, arm.shadowPivot), (sprite, arm.sprite, arm.pivot)] {
                let rect = RoomLayout.rect(bounds)
                let pin = place(CGPoint(x: pivot[0], y: pivot[1]))
                let turned = CGAffineTransform(translationX: rect.minX * width - pin.x, y: (1 - rect.maxY) * height - pin.y)
                    // Clockwise on screen is a negative angle when measuring upwards.
                    .concatenating(CGAffineTransform(rotationAngle: -arm.rest))
                    .concatenating(CGAffineTransform(translationX: pin.x, y: pin.y))
                picture = CIImage(cgImage: image).transformed(by: turned).composited(over: picture)
            }
        }

        return CIContext().createCGImage(picture, from: plate.extent)
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

/// Keeps the Mac's wallpaper the same picture as the scene, for as long as the listener
/// asks for that, and gives their own wallpaper back when they stop.
///
/// macOS keeps a wallpaper per Space and only lets an app change the one in view, so each
/// Space is brought into line — or put back — as it is visited.
@MainActor
final class WallpaperMatcher {
    private let settings: Settings
    private let folder: URL?
    private var cancellables: Set<AnyCancellable> = []
    private var spaceObserver: NSObjectProtocol?

    init(settings: Settings) {
        self.settings = settings
        // Only the installed app may touch the Mac's wallpaper; a test copy run on its own never does.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        folder = Bundle.main.bundleIdentifier.flatMap { support?.appendingPathComponent($0).appendingPathComponent("Wallpapers") }

        settings.$matchesMacWallpaper
            .combineLatest(settings.$scene)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] matches, scene in
                self?.bringIntoLine(matches: matches, scene: scene)
            }
            .store(in: &cancellables)

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bringIntoLine(matches: self.settings.matchesMacWallpaper, scene: self.settings.scene)
            }
        }
    }

    private func bringIntoLine(matches: Bool, scene: SceneKind) {
        guard let folder else { return }
        let workspace = NSWorkspace.shared

        for screen in NSScreen.screens {
            let current = workspace.desktopImageURL(for: screen)
            let isOurs = current?.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) ?? false

            if matches {
                // Whatever was there before is the listener's own; note it so it can come back.
                if let current, !isOurs {
                    remember(current, options: workspace.desktopImageOptions(for: screen), for: screen)
                }
                guard let file = wallpaperFile(for: scene, in: folder),
                      current?.standardizedFileURL != file.standardizedFileURL
                else { continue }
                do {
                    try workspace.setDesktopImageURL(file, for: screen, options: [
                        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true,
                    ])
                    Log.debug("wallpaper: set to the \(scene.title) scene")
                } catch {
                    Log.debug("wallpaper: couldn't set it — \(error.localizedDescription)")
                }
            } else if isOurs, let original = remembered(for: screen) {
                do {
                    try workspace.setDesktopImageURL(original.url, for: screen, options: original.options)
                    Log.debug("wallpaper: put back \(original.url.lastPathComponent)")
                } catch {
                    Log.debug("wallpaper: couldn't put the original back — \(error.localizedDescription)")
                }
            }
        }
    }

    /// The scene's wallpaper picture on disk, made the first time it's wanted. The name
    /// carries the photograph's size, so a re-rendered scene gets a fresh file: macOS won't
    /// reload a wallpaper whose path hasn't changed.
    private func wallpaperFile(for scene: SceneKind, in folder: URL) -> URL? {
        guard let assets = RoomAssets.load(scene) else { return nil }
        let file = folder.appendingPathComponent("\(scene.assetName)-\(assets.plateByteCount).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let picture = SceneWallpaper.picture(for: scene), SceneWallpaper.write(picture, to: file) else { return nil }
        return file
    }

    // MARK: - The listener's own wallpaper

    private func key(_ screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        return "ownWallpaper.\(number)"
    }

    private func remember(_ url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any]?, for screen: NSScreen) {
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: key(screen))
        defaults.set((options?[.imageScaling] as? NSNumber)?.intValue, forKey: key(screen) + ".scaling")
        defaults.set(options?[.allowClipping] as? Bool ?? true, forKey: key(screen) + ".clipping")
    }

    private func remembered(for screen: NSScreen) -> (url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any])? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: key(screen)), FileManager.default.fileExists(atPath: path) else { return nil }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [.allowClipping: defaults.bool(forKey: key(screen) + ".clipping")]
        if let scaling = defaults.object(forKey: key(screen) + ".scaling") as? Int {
            options[.imageScaling] = scaling
        }
        return (URL(fileURLWithPath: path), options)
    }
}
