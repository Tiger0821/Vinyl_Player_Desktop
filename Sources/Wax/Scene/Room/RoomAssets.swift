import AppKit
import ImageIO

/// What `Art/room_scene.py` records about a scene's photograph: where the paintable surfaces
/// sit in it, and enough about the camera and lights to place new things on the tabletop.
/// Positions in the picture are fractions of it, measured from the top-left corner.
struct RoomLayout: Decodable {
    /// A tonearm photographed on its own, to be turned about its pivot. Only a view from
    /// straight above allows this; seen at an angle, a swinging arm changes shape.
    struct Arm: Decodable {
        /// The point the arm turns about, and the point its shadow turns about.
        let pivot: [CGFloat]
        let shadowPivot: [CGFloat]
        /// Where the arm's picture and its shadow's picture sit: min x, min y, max x, max y.
        let sprite: [CGFloat]
        let shadow: [CGFloat]
        /// Clockwise turns, in radians, from the pose it was photographed in: parked, at the
        /// first groove, and at the last.
        let rest: CGFloat
        let leadIn: CGFloat
        let runOut: CGFloat
    }

    struct Pile: Decodable {
        /// Where the pile stands on the table, in metres.
        let centre: [CGFloat]
        /// Edge length and thickness of one sleeve, in metres.
        let size: CGFloat
        let thickness: CGFloat
        /// How a sleeve dropped there tends to lie, in degrees anticlockwise from above.
        let turn: CGFloat
    }

    struct LightCard: Decodable {
        let centre: [CGFloat]
        let size: CGFloat
        let height: CGFloat
        /// The card's rectangle in the picture: min x, min y, max x, max y.
        let patch: [CGFloat]
    }

    struct Light: Decodable {
        /// How far a shadow lands from its caster, in metres per metre of height.
        let shadow: [CGFloat]
        /// Blur of a shadow's edge, in metres.
        let softness: CGFloat
        let strength: Float
    }

    /// The photograph's size in pixels, as rendered.
    let size: [CGFloat]
    /// The camera, as the twelve numbers `project` multiplies by.
    let camera: [CGFloat]
    let cameraPosition: [CGFloat]
    /// Corners in the order top-left, top-right, bottom-right, bottom-left of the artwork.
    let sleeve: [[CGFloat]]
    /// The square the record label is inscribed in, lying flat on the platter.
    let label: [[CGFloat]]
    /// For a scene seen at an angle: the part of the picture that changes when the tonearm
    /// moves, which a second photograph replaces. Min x, min y, max x, max y.
    let armPatch: [CGFloat]?
    /// For a scene seen from above: the arm as a cut-out to be turned.
    let arm: Arm?
    let pile: Pile
    let lightCard: LightCard
    /// Per room, keyed by its file name.
    let scenes: [String: Light]

    static func points(_ corners: [[CGFloat]]) -> [CGPoint] {
        corners.map { CGPoint(x: $0[0], y: $0[1]) }
    }

    static func rect(_ bounds: [CGFloat]) -> CGRect {
        CGRect(x: bounds[0], y: bounds[1], width: bounds[2] - bounds[0], height: bounds[3] - bounds[1])
    }

    var armRect: CGRect? { armPatch.map(Self.rect) }

    /// Where a point in the room, in metres, appears in the picture.
    func project(x: CGFloat, y: CGFloat, z: CGFloat) -> CGPoint {
        let m = camera
        let depth = m[8] * x + m[9] * y + m[10] * z + m[11]
        return CGPoint(
            x: (m[0] * x + m[1] * y + m[2] * z + m[3]) / depth,
            y: (m[4] * x + m[5] * y + m[6] * z + m[7]) / depth
        )
    }
}

/// Everything needed to draw one room: the photograph, and the pieces cut from it that let
/// artwork be painted in as though it had been in the room when the picture was taken.
///
/// In the photograph the sleeve and the record label are blank white card, so their pixels
/// hold only the light falling on them. Artwork laid over them and multiplied by those
/// pixels picks up the room's light and shadow.
final class RoomAssets {
    let name: String
    let layout: RoomLayout
    let light: RoomLayout.Light
    /// The scene with the tonearm parked — or, where the arm is a cut-out, with no arm at all.
    let plate: CGImage
    /// The turntable alone with the tonearm on the record; drawn over `layout.armRect`.
    let armPatch: CGImage?
    /// The tonearm and its shadow as cut-outs, where the layout has an `arm`.
    let armSprite: CGImage?
    let armShadow: CGImage?
    /// Opaque where the sleeve shows, clear elsewhere.
    let surfaceMask: CGImage
    /// The record label's box in the picture, as fractions of it.
    let labelBox: CGRect
    /// Opaque where the label shows, within `labelBox`.
    let labelMask: CGImage
    /// The light on the label, within `labelBox`, with the tonearm parked and on the record.
    let labelLightParked: CGImage
    let labelLightPlaying: CGImage
    /// The light falling on the tabletop where the pile stands, seen from straight above:
    /// left to right is the room's x, top to bottom runs from the wall towards the camera.
    let tableLight: CGImage
    /// The average of `tableLight`, for shading things too small to need the detail.
    let tableTone: (red: CGFloat, green: CGFloat, blue: CGFloat)
    /// The size of the photograph's file, which changes whenever the scene is re-rendered.
    let plateByteCount: Int

    private static var cache: [String: RoomAssets] = [:]

    /// The folder holding the renders: inside the app, or wherever a test points.
    private static let folder: URL? = {
        if let override = ProcessInfo.processInfo.environment["WAX_SCENES_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("Scenes")
    }()

    /// `maxPixelWidth` loads a reduced copy, for thumbnails. Full-size copies of other rooms
    /// are dropped when a new one loads, since each is tens of megabytes decoded.
    static func load(_ kind: SceneKind, maxPixelWidth: Int? = nil) -> RoomAssets? {
        guard let folder else { return nil }
        let name = kind.assetName
        let key = "\(name)@\(maxPixelWidth ?? 0)"
        if let cached = cache[key] { return cached }

        guard let loaded = RoomAssets(name: name, layoutName: kind.layoutName, folder: folder, maxPixelWidth: maxPixelWidth) else {
            Log.debug("room: couldn't load “\(name)” from \(folder.path)")
            return nil
        }
        if maxPixelWidth == nil {
            cache = cache.filter { !$0.key.hasSuffix("@0") }
        }
        cache[key] = loaded
        return loaded
    }

    private init?(name: String, layoutName: String, folder: URL, maxPixelWidth: Int?) {
        func file(_ suffix: String) -> URL { folder.appendingPathComponent(name + suffix) }

        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(layoutName).json")),
              let layout = try? JSONDecoder().decode(RoomLayout.self, from: data),
              let light = layout.scenes[name]
        else { return nil }

        /// The longest side, in pixels, that a piece of the picture needs in a reduced copy.
        func reduced(_ piece: CGRect) -> Int? {
            maxPixelWidth.map { width in
                let height = CGFloat(width) * layout.size[1] / layout.size[0]
                return max(48, Int(max(piece.width * CGFloat(width), piece.height * height)))
            }
        }

        guard let plate = Self.image(file(".jpg"), maxPixel: maxPixelWidth),
              let mask = Self.image(folder.appendingPathComponent("\(layoutName)-mask.png"), maxPixel: maxPixelWidth),
              let lightPatch = Self.image(file("-light.jpg"), maxPixel: reduced(RoomLayout.rect(layout.lightCard.patch)))
        else { return nil }

        let armPatch = layout.armRect.flatMap { Self.image(file("-arm.jpg"), maxPixel: reduced($0)) }
        let armSprite = layout.arm.flatMap { Self.image(file("-arm.png"), maxPixel: reduced(RoomLayout.rect($0.sprite))) }
        let armShadow = layout.arm.flatMap { Self.image(file("-arm-shadow.png"), maxPixel: reduced(RoomLayout.rect($0.shadow))) }
        // One or the other, depending on how the scene handles its arm.
        guard armPatch != nil || (armSprite != nil && armShadow != nil) else { return nil }

        // The label's bounding box, with a pixel or two to spare for its soft edge.
        let corners = RoomLayout.points(layout.label)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let margin: CGFloat = 0.003
        let box = CGRect(
            x: xs.min()! - margin, y: ys.min()! - margin,
            width: xs.max()! - xs.min()! + margin * 2, height: ys.max()! - ys.min()! + margin * 2
        )

        guard let masks = Self.splitMask(mask, labelBox: box),
              let parked = plate.cropping(to: Self.pixels(box, in: plate)),
              let table = Self.tableLight(from: lightPatch, layout: layout)
        else { return nil }

        // Where the arm is a second photograph, the label's light comes from that one while a
        // record is on. A cut-out arm carries its own shadow, so the label's light never changes.
        var playing = parked
        if let armPatch, let armRect = layout.armRect {
            let within = CGRect(
                x: (box.minX - armRect.minX) / armRect.width, y: (box.minY - armRect.minY) / armRect.height,
                width: box.width / armRect.width, height: box.height / armRect.height
            )
            guard let cut = armPatch.cropping(to: Self.pixels(within, in: armPatch)) else { return nil }
            playing = cut
        }

        self.name = name
        self.layout = layout
        self.light = light
        self.plate = plate
        self.armPatch = armPatch
        self.armSprite = armSprite
        self.armShadow = armShadow
        self.labelBox = box
        self.surfaceMask = masks.surfaces
        self.labelMask = masks.label
        self.labelLightParked = parked
        self.labelLightPlaying = playing
        self.tableLight = table.image
        self.tableTone = table.tone
        self.plateByteCount = (try? file(".jpg").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: - Loading

    private static func image(_ url: URL, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func pixels(_ fraction: CGRect, in image: CGImage) -> CGRect {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return CGRect(
            x: (fraction.minX * width).rounded(.down),
            y: (fraction.minY * height).rounded(.down),
            width: (fraction.width * width).rounded(.up),
            height: (fraction.height * height).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Reads an image's pixels as plain bytes, top row first.
    private static func bytes(of image: CGImage, grey: Bool) -> [UInt8]? {
        let width = image.width, height = image.height, channels = grey ? 1 : 4
        var buffer = [UInt8](repeating: 0, count: width * height * channels)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * channels,
                space: grey ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? buffer : nil
    }

    private static func picture(_ rgba: [UInt8], width: Int, height: Int, alpha: CGImageAlphaInfo) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Turns the black-and-white mask into two see-through stencils: the label on its own,
    /// and everything else. A layer mask reads transparency, not brightness.
    private static func splitMask(_ mask: CGImage, labelBox: CGRect) -> (surfaces: CGImage, label: CGImage)? {
        let width = mask.width, height = mask.height
        guard let grey = bytes(of: mask, grey: true) else { return nil }

        let box = pixels(labelBox, in: mask)
        let boxX = Int(box.minX), boxY = Int(box.minY), boxW = Int(box.width), boxH = Int(box.height)
        guard boxW > 0, boxH > 0 else { return nil }

        var surfaces = [UInt8](repeating: 0, count: width * height * 4)
        var label = [UInt8](repeating: 0, count: boxW * boxH * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = grey[y * width + x]
                guard value > 0 else { continue }
                let inBox = x >= boxX && x < boxX + boxW && y >= boxY && y < boxY + boxH
                if inBox {
                    let index = ((y - boxY) * boxW + (x - boxX)) * 4
                    label[index] = value; label[index + 1] = value; label[index + 2] = value; label[index + 3] = value
                } else {
                    let index = (y * width + x) * 4
                    surfaces[index] = value; surfaces[index + 1] = value; surfaces[index + 2] = value; surfaces[index + 3] = value
                }
            }
        }

        guard let surfaceImage = picture(surfaces, width: width, height: height, alpha: .premultipliedLast),
              let labelImage = picture(label, width: boxW, height: boxH, alpha: .premultipliedLast)
        else { return nil }
        return (surfaceImage, labelImage)
    }

    /// Flattens the photographed light card into a map seen from above, by asking the camera
    /// where each point of the card landed in the photograph.
    private static func tableLight(
        from patch: CGImage, layout: RoomLayout
    ) -> (image: CGImage, tone: (red: CGFloat, green: CGFloat, blue: CGFloat))? {
        guard let source = bytes(of: patch, grey: false) else { return nil }
        let card = layout.lightCard
        let frame = RoomLayout.rect(card.patch)
        let side = 160
        var map = [UInt8](repeating: 255, count: side * side * 4)
        var sum = (0, 0, 0)

        for row in 0..<side {
            for column in 0..<side {
                let x = card.centre[0] + ((CGFloat(column) + 0.5) / CGFloat(side) - 0.5) * card.size
                let y = card.centre[1] + (0.5 - (CGFloat(row) + 0.5) / CGFloat(side)) * card.size
                let seen = layout.project(x: x, y: y, z: card.height)
                // Part of the card lies beyond the picture's edge; borrow the nearest pixel.
                let px = min(patch.width - 1, max(0, Int((seen.x - frame.minX) / frame.width * CGFloat(patch.width))))
                let py = min(patch.height - 1, max(0, Int((seen.y - frame.minY) / frame.height * CGFloat(patch.height))))
                let from = (py * patch.width + px) * 4, to = (row * side + column) * 4
                map[to] = source[from]; map[to + 1] = source[from + 1]; map[to + 2] = source[from + 2]
                sum.0 += Int(source[from]); sum.1 += Int(source[from + 1]); sum.2 += Int(source[from + 2])
            }
        }

        guard let image = picture(map, width: side, height: side, alpha: .noneSkipLast) else { return nil }
        let count = CGFloat(side * side) * 255
        return (image, (CGFloat(sum.0) / count, CGFloat(sum.1) / count, CGFloat(sum.2) / count))
    }
}

/// The transform that carries a `size` rectangle onto an arbitrary four-cornered shape,
/// which is what a flat card looks like when photographed at an angle.
extension CATransform3D {
    /// `corners` are the destination of the rectangle's top-left, top-right, bottom-right and
    /// bottom-left, in the parent layer's coordinates. The layer must have its anchor point
    /// and position both at the origin.
    init(mapping size: CGSize, onto corners: [CGPoint]) {
        let p0 = corners[0], p1 = corners[1], p2 = corners[2], p3 = corners[3]
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, sx = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, sy = p0.y - p1.y + p2.y - p3.y

        // How strongly the shape converges horizontally and vertically.
        let denominator = dx1 * dy2 - dx2 * dy1
        let g = denominator == 0 ? 0 : (sx * dy2 - dx2 * sy) / denominator
        let h = denominator == 0 ? 0 : (dx1 * sy - sx * dy1) / denominator

        let a = p1.x - p0.x + g * p1.x, b = p3.x - p0.x + h * p3.x
        let d = p1.y - p0.y + g * p1.y, e = p3.y - p0.y + h * p3.y

        self.init(
            m11: a / size.width, m12: d / size.width, m13: 0, m14: g / size.width,
            m21: b / size.height, m22: e / size.height, m23: 0, m24: h / size.height,
            m31: 0, m32: 0, m33: 1, m34: 0,
            m41: p0.x, m42: p0.y, m43: 0, m44: 1
        )
    }
}
