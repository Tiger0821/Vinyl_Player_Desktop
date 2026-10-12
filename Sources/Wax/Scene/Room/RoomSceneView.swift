import AppKit
import SwiftUI

/// A scene's photograph with the listener's records painted into it: the current cover on
/// the sleeve and on the record's label as it turns, the tonearm following the song, and
/// every record played so far in a pile on the table.
struct RoomSceneLayerView: NSViewRepresentable {
    let kind: SceneKind
    let artwork: NSImage?
    let track: Track?
    let pile: [DeskStore.Record]
    let cover: (DeskStore.Record) -> CGImage?
    /// Set for thumbnails, to load a reduced copy of the photograph.
    var maxPixelWidth: Int?

    func makeNSView(context: Context) -> RoomSceneView {
        RoomSceneView(maxPixelWidth: maxPixelWidth)
    }

    func updateNSView(_ view: RoomSceneView, context: Context) {
        view.show(kind: kind, artwork: artwork, track: track, pile: pile, cover: cover)
    }
}

final class RoomSceneView: NSView {
    private static let spinKey = "spin"
    private static let rotation = "transform.rotation.z"
    /// Working size of the flat layers that get bent into the photograph. Only their shape matters.
    private static let card = CGSize(width: 512, height: 512)

    private let maxPixelWidth: Int?
    private var kind: SceneKind?
    private var assets: RoomAssets?
    private var isSpinning = false
    private var track: Track?
    private var records: [DeskStore.Record] = []
    private var cover: (DeskStore.Record) -> CGImage? = { _ in nil }

    /// Everything is laid out in the photograph's own frame, origin top-left.
    private let stage = CALayer()
    private let plateLayer = CALayer()
    private let armLayer = CALayer()
    private let pile = RoomPile()
    private let surfaces = CALayer()
    private let sleeveLayer = CALayer()
    private let surfaceLight = CALayer()
    private let labelGroup = CALayer()
    private let labelPlane = CALayer()
    private let labelDisc = CALayer()
    private let labelLight = CALayer()
    private let armShadowLayer = CALayer()
    private let armSpriteLayer = CALayer()
    private let surfacesMask = CALayer()
    private let surfaceLightMask = CALayer()
    private let labelGroupMask = CALayer()
    private let labelLightMask = CALayer()

    init(maxPixelWidth: Int?) {
        self.maxPixelWidth = maxPixelWidth
        super.init(frame: .zero)

        let root = CALayer()
        root.masksToBounds = true
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true

        for card in [sleeveLayer, labelPlane] {
            card.anchorPoint = .zero
            card.bounds = CGRect(origin: .zero, size: Self.card)
        }
        for picture in [sleeveLayer, labelDisc] {
            picture.contentsGravity = .resizeAspectFill
            picture.masksToBounds = true
        }
        labelDisc.frame = CGRect(origin: .zero, size: Self.card)
        labelDisc.cornerRadius = Self.card.width / 2
        labelDisc.actions = ["transform": NSNull()]
        labelPlane.addSublayer(labelDisc)
        // The arm's turns are animated explicitly; nothing about it should move on its own.
        for cutOut in [armShadowLayer, armSpriteLayer] {
            cutOut.actions = ["transform": NSNull(), "bounds": NSNull(), "position": NSNull(), "anchorPoint": NSNull()]
        }

        // Multiplying the photograph back over the artwork is what lights it.
        for light in [surfaceLight, labelLight] {
            light.compositingFilter = "multiplyBlendMode"
        }
        surfaces.mask = surfacesMask
        surfaceLight.mask = surfaceLightMask
        labelGroup.mask = labelGroupMask
        labelLight.mask = labelLightMask

        surfaces.addSublayer(sleeveLayer)
        labelGroup.addSublayer(labelPlane)
        for sublayer in [
            plateLayer, armLayer, pile.ground, pile.sleeves, surfaces, surfaceLight, labelGroup, labelLight,
            armShadowLayer, armSpriteLayer,
        ] {
            stage.addSublayer(sublayer)
        }
        root.addSublayer(stage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Measured from the top-left, like the photograph. AppKit flips the layer tree to match.
    override var isFlipped: Bool { true }

    // MARK: - State

    func show(
        kind: SceneKind, artwork: NSImage?, track: Track?,
        pile records: [DeskStore.Record], cover: @escaping (DeskStore.Record) -> CGImage?
    ) {
        let hasTrack = track != nil
        let sceneChanged = kind != self.kind
        if sceneChanged {
            self.kind = kind
            assets = RoomAssets.load(kind, maxPixelWidth: maxPixelWidth)
            withoutAnimation {
                plateLayer.contents = assets?.plate
                armLayer.contents = assets?.armPatch
                armSpriteLayer.contents = assets?.armSprite
                armShadowLayer.contents = assets?.armShadow
                surfaceLight.contents = assets?.plate
                for mask in [surfacesMask, surfaceLightMask] { mask.contents = assets?.surfaceMask }
                for mask in [labelGroupMask, labelLightMask] { mask.contents = assets?.labelMask }
            }
            needsLayout = true
        }

        setPicture(artwork ?? DefaultArt.sleeve, on: sleeveLayer)
        setPicture(artwork ?? DefaultLabelArt.image, on: labelDisc)

        // The arm sits on the record whenever one is loaded, playing or paused.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.7)
        armLayer.opacity = hasTrack ? 1 : 0
        labelLight.contents = hasTrack ? assets?.labelLightPlaying : assets?.labelLightParked
        CATransaction.commit()

        self.cover = cover
        if records != self.records {
            self.records = records
            layoutPile()
        }

        // Only a real change in the song restarts the arm; other updates leave it gliding.
        if sceneChanged || track != self.track {
            self.track = track
            if sceneChanged {
                layoutSubtreeIfNeeded()
            }
            swingArm(animated: !sceneChanged)
        }

        isSpinning = track?.isPlaying == true
        updateSpin()
    }

    /// Carries a cut-out arm to where the song has got to, then lets it follow the song to
    /// the end of the side. The animation runs in the window server, so the needle tracks
    /// smoothly for minutes without this app doing anything.
    private func swingArm(animated: Bool) {
        guard let arm = assets?.layout.arm else { return }
        let now = Date()
        func turn(at date: Date) -> CGFloat {
            guard let track else { return arm.rest }
            return arm.leadIn + (arm.runOut - arm.leadIn) * CGFloat(track.progress(at: date))
        }
        let target = turn(at: now)

        for layer in [armSpriteLayer, armShadowLayer] {
            let current = layer.presentation()?.value(forKeyPath: Self.rotation) as? CGFloat
                ?? layer.value(forKeyPath: Self.rotation) as? CGFloat ?? arm.rest
            layer.removeAnimation(forKey: "follow")
            layer.removeAnimation(forKey: "settle")
            layer.setValue(target, forKeyPath: Self.rotation)

            // A long swing, as when a record goes on, takes its time; a small correction doesn't.
            let settleTime: CFTimeInterval = animated ? (abs(target - current) > 0.02 ? 1.1 : 0.3) : 0
            if settleTime > 0 {
                let settle = CABasicAnimation(keyPath: Self.rotation)
                settle.fromValue = current
                settle.toValue = target
                settle.duration = settleTime
                settle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(settle, forKey: "settle")
            }

            guard let track, track.isPlaying, track.info.duration > 0 else { continue }
            let remaining = track.info.duration - track.position(at: now) - settleTime
            guard remaining > 1 else { continue }
            let follow = CABasicAnimation(keyPath: Self.rotation)
            follow.fromValue = turn(at: now.addingTimeInterval(settleTime))
            follow.toValue = arm.runOut
            follow.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + settleTime
            follow.duration = remaining
            follow.fillMode = .forwards
            follow.isRemovedOnCompletion = false
            layer.add(follow, forKey: "follow")
        }
    }

    private func setPicture(_ image: NSImage, on layer: CALayer) {
        guard (layer.value(forKey: "waxPicture") as? NSImage) !== image else { return }
        if layer.contents != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.7
            layer.add(fade, forKey: "contents")
        }
        layer.setValue(image, forKey: "waxPicture")
        layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func updateSpin() {
        let turning = isSpinning && window != nil
        if turning {
            guard labelDisc.animation(forKey: Self.spinKey) == nil else { return }
            let start = labelDisc.value(forKeyPath: Self.rotation) as? CGFloat ?? 0
            let spin = CABasicAnimation(keyPath: Self.rotation)
            spin.fromValue = start
            // This layer tree measures downwards, where a growing angle is a clockwise turn.
            spin.toValue = start + 2 * CGFloat.pi
            spin.duration = SpinningDiscView.secondsPerTurn
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            labelDisc.add(spin, forKey: Self.spinKey)
        } else if labelDisc.animation(forKey: Self.spinKey) != nil {
            let angle = labelDisc.presentation()?.value(forKeyPath: Self.rotation) as? CGFloat ?? 0
            labelDisc.removeAnimation(forKey: Self.spinKey)
            labelDisc.setValue(angle, forKeyPath: Self.rotation)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpin()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let assets else { return }

        // Fill the view with the photograph, cropping whichever dimension overflows.
        let picture = CGSize(width: assets.plate.width, height: assets.plate.height)
        let scale = max(bounds.width / picture.width, bounds.height / picture.height)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        let full = CGRect(origin: .zero, size: size)

        func placed(_ fraction: CGRect) -> CGRect {
            CGRect(x: fraction.minX * size.width, y: fraction.minY * size.height,
                   width: fraction.width * size.width, height: fraction.height * size.height)
        }
        func placed(_ corners: [[CGFloat]], relativeTo origin: CGPoint = .zero) -> [CGPoint] {
            RoomLayout.points(corners).map { CGPoint(x: $0.x * size.width - origin.x, y: $0.y * size.height - origin.y) }
        }

        withoutAnimation {
            stage.frame = CGRect(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height
            )
            for layer in [plateLayer, surfaces, surfaceLight, surfacesMask, surfaceLightMask] {
                layer.frame = full
            }
            if let armRect = assets.layout.armRect {
                armLayer.frame = placed(armRect)
            }
            if let arm = assets.layout.arm {
                // Each cut-out turns about its own pivot, so that is where it is pinned.
                for (layer, rect, pivot) in [
                    (armSpriteLayer, arm.sprite, arm.pivot), (armShadowLayer, arm.shadow, arm.shadowPivot),
                ] {
                    let frame = placed(RoomLayout.rect(rect))
                    let pin = CGPoint(x: pivot[0] * size.width, y: pivot[1] * size.height)
                    layer.anchorPoint = CGPoint(x: (pin.x - frame.minX) / frame.width, y: (pin.y - frame.minY) / frame.height)
                    layer.bounds = CGRect(origin: .zero, size: frame.size)
                    layer.position = pin
                }
            }
            sleeveLayer.transform = CATransform3D(mapping: Self.card, onto: placed(assets.layout.sleeve))

            let labelFrame = placed(assets.labelBox)
            labelGroup.frame = labelFrame
            labelLight.frame = labelFrame
            for mask in [labelGroupMask, labelLightMask] {
                mask.frame = CGRect(origin: .zero, size: labelFrame.size)
            }
            labelPlane.transform = CATransform3D(mapping: Self.card, onto: placed(assets.layout.label, relativeTo: labelFrame.origin))
        }
        layoutPile()
    }

    private func layoutPile() {
        guard let assets, stage.bounds.width > 0 else { return }
        pile.show(records, cover: cover, assets: assets, stage: stage.bounds.size)
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}

/// The cover for when there is nothing of the listener's to show.
@MainActor
enum DefaultArt {
    static let sleeve: NSImage = {
        let renderer = ImageRenderer(content: PlaceholderCover(track: nil, unit: 1).frame(width: 480, height: 480))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: 480, height: 480))
    }()
}
