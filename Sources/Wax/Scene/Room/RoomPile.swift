import AppKit

/// Draws the pile of played records on the tabletop of a room photograph.
///
/// The pile isn't in the photograph, because it grows. Each sleeve is put where the room's
/// camera would have seen it, lit by the light measured on that patch of table, and shaded
/// by the sleeve above it — the things a render would have got right on its own.
final class RoomPile {
    /// The tabletop itself, as a layer lying flat on it: where the pile's shadow is drawn.
    let ground = CALayer()
    /// The sleeves, bottom first.
    let sleeves = CALayer()

    private static let face = CGSize(width: 384, height: 384)
    /// The square of tabletop `ground` covers, in metres either side of the pile.
    private static let groundReach: CGFloat = 0.9
    private static let groundSide: CGFloat = 1536

    private let shadow = CALayer()
    private var shownIDs: [UUID] = []
    private var shownScene = ""
    private var lit: [String: CGImage] = [:]

    init() {
        ground.anchorPoint = .zero
        ground.bounds = CGRect(x: 0, y: 0, width: Self.groundSide, height: Self.groundSide)
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOffset = .zero
        ground.addSublayer(shadow)
    }

    /// One sleeve's place in the room, in metres.
    private struct Placement {
        let centre: CGPoint
        let turn: CGFloat
        let bottom: CGFloat
        let top: CGFloat
        let half: CGFloat

        /// The top face's corners on the table plan: far-left, far-right, near-right, near-left.
        var corners: [CGPoint] {
            [(-half, half), (half, half), (half, -half), (-half, -half)].map { plan($0.0, $0.1) }
        }

        /// A point given across and along the sleeve, as a point on the table plan.
        func plan(_ across: CGFloat, _ along: CGFloat) -> CGPoint {
            CGPoint(
                x: centre.x + across * cos(turn) - along * sin(turn),
                y: centre.y + across * sin(turn) + along * cos(turn)
            )
        }

        /// A point on the table plan as a point on this sleeve's face, in the face layer's units.
        func onFace(_ point: CGPoint, side: CGFloat) -> CGPoint {
            let dx = point.x - centre.x, dy = point.y - centre.y
            let across = dx * cos(turn) + dy * sin(turn)
            let along = -dx * sin(turn) + dy * cos(turn)
            return CGPoint(x: (across / (half * 2) + 0.5) * side, y: (0.5 - along / (half * 2)) * side)
        }
    }

    // MARK: - Drawing

    func show(
        _ records: [DeskStore.Record],
        cover: (DeskStore.Record) -> CGImage?,
        assets: RoomAssets,
        stage: CGSize
    ) {
        let ids = records.map(\.id)
        // A record dropped on top of what was already there arrives with a little movement.
        let isOneMore = shownScene == assets.name && ids.count == shownIDs.count + 1 && Array(ids.dropLast()) == shownIDs
        let wasCleared = ids.isEmpty && !shownIDs.isEmpty
        if shownScene != assets.name { lit.removeAll() }
        shownIDs = ids
        shownScene = assets.name

        let layout = assets.layout
        let pile = layout.pile
        let placements = records.enumerated().map { index, record -> Placement in
            var random = SplitMix64(seed: record.seed)
            // Most land squarely; now and then one is put down carelessly.
            let reach: CGFloat = CGFloat.random(in: 0..<1, using: &random) < 0.15 ? 0.022 : 0.009
            let turn = (pile.turn + CGFloat.random(in: -9...9, using: &random)) * .pi / 180
            return Placement(
                centre: CGPoint(
                    x: pile.centre[0] + CGFloat.random(in: -reach...reach, using: &random),
                    y: pile.centre[1] + CGFloat.random(in: -reach...reach, using: &random)
                ),
                turn: turn,
                bottom: CGFloat(index) * pile.thickness,
                top: CGFloat(index + 1) * pile.thickness,
                half: pile.size / 2
            )
        }

        func seen(_ point: CGPoint, height: CGFloat) -> CGPoint {
            let fraction = layout.project(x: point.x, y: point.y, z: height)
            return CGPoint(x: fraction.x * stage.width, y: fraction.y * stage.height)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if wasCleared {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.6
            sleeves.add(fade, forKey: "clear")
            ground.add(fade, forKey: "clear")
        }

        sleeves.frame = CGRect(origin: .zero, size: stage)
        sleeves.sublayers?.forEach { $0.removeFromSuperlayer() }

        let cast = CGPoint(x: assets.light.shadow[0], y: assets.light.shadow[1])
        let castLength = hypot(cast.x, cast.y)
        let towardsLight = castLength > 0 ? CGPoint(x: -cast.x / castLength, y: -cast.y / castLength) : .zero
        let eye = CGPoint(x: layout.cameraPosition[0], y: layout.cameraPosition[1])

        for (index, placement) in placements.enumerated() {
            let record = records[index]
            let group = CALayer()
            group.frame = sleeves.bounds

            guard let art = cover(record) else { continue }
            let average = Self.averageColour(of: art)

            // The edges of the sleeve that face the camera.
            let corners = placement.corners
            let normals: [(CGFloat, CGFloat)] = [(0, 1), (1, 0), (0, -1), (-1, 0)]
            for side in 0..<4 {
                let from = corners[side], to = corners[(side + 1) % 4]
                let normal = CGPoint(
                    x: normals[side].0 * cos(placement.turn) - normals[side].1 * sin(placement.turn),
                    y: normals[side].0 * sin(placement.turn) + normals[side].1 * cos(placement.turn)
                )
                let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                guard normal.x * (eye.x - middle.x) + normal.y * (eye.y - middle.y) > 0 else { continue }

                let path = CGMutablePath()
                path.addLines(between: [
                    seen(from, height: placement.top), seen(to, height: placement.top),
                    seen(to, height: placement.bottom), seen(from, height: placement.bottom),
                ])
                path.closeSubpath()

                // Card edge, tinted by the cover, brighter where it faces the light.
                let facing = max(0, normal.x * towardsLight.x + normal.y * towardsLight.y)
                let lightness = 0.5 + 0.5 * facing
                let edge = CAShapeLayer()
                edge.path = path
                edge.fillColor = CGColor(
                    srgbRed: (0.62 + 0.38 * average.red) * assets.tableTone.red * lightness,
                    green: (0.6 + 0.4 * average.green) * assets.tableTone.green * lightness,
                    blue: (0.56 + 0.44 * average.blue) * assets.tableTone.blue * lightness,
                    alpha: 1
                )
                group.addSublayer(edge)
            }

            // The printed face, bent into the photograph.
            let face = CALayer()
            face.anchorPoint = .zero
            face.bounds = CGRect(origin: .zero, size: Self.face)
            face.masksToBounds = true
            face.contents = litCover(art, record: record, placement: placement, assets: assets)
            face.transform = CATransform3D(mapping: Self.face, onto: corners.map { seen($0, height: placement.top) })

            // The sleeve above keeps a little light off this one.
            if index + 1 < placements.count {
                let above = placements[index + 1]
                let reach = pile.thickness
                let outline = CGMutablePath()
                for step in [0, reach] {
                    let moved = above.corners.map { CGPoint(x: $0.x + cast.x * step, y: $0.y + cast.y * step) }
                    outline.addLines(between: moved.map { placement.onFace($0, side: Self.face.width) })
                    outline.closeSubpath()
                }
                let shade = CALayer()
                shade.shadowPath = outline
                shade.shadowColor = NSColor.black.cgColor
                shade.shadowOffset = .zero
                shade.shadowOpacity = assets.light.strength
                shade.shadowRadius = max(2, assets.light.softness / pile.size * Self.face.width)
                face.addSublayer(shade)
            }
            group.addSublayer(face)
            sleeves.addSublayer(group)

            if isOneMore, index == placements.count - 1 {
                let drop = CABasicAnimation(keyPath: "position.y")
                drop.fromValue = group.position.y - stage.height * 0.03
                drop.toValue = group.position.y
                let appear = CABasicAnimation(keyPath: "opacity")
                appear.fromValue = 0
                appear.toValue = 1
                let arrival = CAAnimationGroup()
                arrival.animations = [drop, appear]
                arrival.duration = 0.55
                arrival.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.add(arrival, forKey: "arrive")
            }
        }

        layoutGround(placements, cast: cast, assets: assets, seen: seen)
        CATransaction.commit()
    }

    /// The shadow the whole pile throws across the table: everything between each sleeve's
    /// footprint and where the light carries its outline.
    private func layoutGround(
        _ placements: [Placement], cast: CGPoint, assets: RoomAssets, seen: (CGPoint, CGFloat) -> CGPoint
    ) {
        let pile = assets.layout.pile
        let reach = Self.groundReach, side = Self.groundSide
        let origin = CGPoint(x: pile.centre[0] - reach, y: pile.centre[1] + reach)
        let scale = side / (reach * 2)

        let plan = [
            origin, CGPoint(x: origin.x + reach * 2, y: origin.y),
            CGPoint(x: origin.x + reach * 2, y: origin.y - reach * 2), CGPoint(x: origin.x, y: origin.y - reach * 2),
        ]
        ground.transform = CATransform3D(mapping: ground.bounds.size, onto: plan.map { seen($0, 0) })

        guard let tallest = placements.last else {
            shadow.shadowOpacity = 0
            return
        }
        var reached: [CGPoint] = []
        for placement in placements {
            for corner in placement.corners {
                reached.append(corner)
                reached.append(CGPoint(x: corner.x + cast.x * placement.top, y: corner.y + cast.y * placement.top))
            }
        }
        let outline = CGMutablePath()
        outline.addLines(between: Self.hull(reached).map { CGPoint(x: ($0.x - origin.x) * scale, y: (origin.y - $0.y) * scale) })
        outline.closeSubpath()

        shadow.shadowPath = outline
        shadow.shadowOpacity = assets.light.strength
        // A shadow blurs more the further it falls from what casts it.
        shadow.shadowRadius = (assets.light.softness + tallest.top * 0.12) * scale
    }

    // MARK: - Lighting

    /// The cover as the room lights it: multiplied by the light on the patch of table it covers.
    private func litCover(_ art: CGImage, record: DeskStore.Record, placement: Placement, assets: RoomAssets) -> CGImage? {
        let key = "\(record.id.uuidString)|\(placement.top)"
        if let done = lit[key] { return done }

        let side = Self.face.width
        guard let context = CGContext(
            data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // Work from the top-left, the way the pictures are measured.
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        Self.draw(art, in: CGRect(x: 0, y: 0, width: side, height: side), context)

        let card = assets.layout.lightCard
        let map = CGFloat(assets.tableLight.width)
        let metresPerPixel = card.size / map
        // Light map → table plan → this sleeve's face.
        let toPlan = CGAffineTransform(
            a: metresPerPixel, b: 0, c: 0, d: -metresPerPixel,
            tx: card.centre[0] - card.size / 2, ty: card.centre[1] + card.size / 2
        )
        let toSleeve = CGAffineTransform(translationX: -placement.centre.x, y: -placement.centre.y)
            .concatenating(CGAffineTransform(rotationAngle: -placement.turn))
        let toFace = CGAffineTransform(a: side / (placement.half * 2), b: 0, c: 0, d: -side / (placement.half * 2), tx: side / 2, ty: side / 2)

        context.setBlendMode(.multiply)
        context.concatenate(toPlan.concatenating(toSleeve).concatenating(toFace))
        Self.draw(assets.tableLight, in: CGRect(x: 0, y: 0, width: map, height: map), context)

        let image = context.makeImage()
        lit[key] = image
        return image
    }

    /// Draws an image upright in a context that measures downwards.
    private static func draw(_ image: CGImage, in rect: CGRect, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func averageColour(of image: CGImage) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            context?.interpolationQuality = .medium
            context?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    /// The tightest outline that takes in every point.
    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }

        func turnsLeft(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0
        }
        func half(_ ordered: [CGPoint]) -> [CGPoint] {
            var chain: [CGPoint] = []
            for point in ordered {
                while chain.count >= 2, !turnsLeft(chain[chain.count - 2], chain[chain.count - 1], point) {
                    chain.removeLast()
                }
                chain.append(point)
            }
            return Array(chain.dropLast())
        }
        return half(sorted) + half(sorted.reversed())
    }
}
