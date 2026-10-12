import AppKit
import SwiftUI

/// The record on the platter. Only the label turns: grooves look the same at every angle,
/// and the sheen belongs to the light, not the disc.
struct RecordView: View {
    let artwork: NSImage?
    let isSpinning: Bool
    let unit: CGFloat
    let isStaticRender: Bool

    /// Label diameter as a share of the record's — 100mm on a 300mm LP.
    private static let labelShare: CGFloat = 0.345
    /// Where the grooves start, as a share of the radius. Inside this is smooth run-out.
    private static let grooveStart: CGFloat = 0.415

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let labelDiameter = diameter * Self.labelShare
            let grooveBand = diameter / 2 * (1 - Self.grooveStart)

            ZStack {
                Circle()
                    .fill(.black.opacity(0.5))
                    .blur(radius: 5 * unit)
                    .offset(x: 3 * unit, y: 5 * unit)
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(white: 0.10), Color(white: 0.035), Color(white: 0.07)],
                        center: .center,
                        startRadius: diameter * 0.17,
                        endRadius: diameter * 0.5
                    ))
                Grooves(start: Self.grooveStart)

                // Broad sheen, then a tight bright core, where the light catches the grooves.
                Circle()
                    .fill(AngularGradient(gradient: Gradient(stops: Self.sheen(width: 0.085, strength: 0.2)), center: .center))
                    .mask(Circle().strokeBorder(lineWidth: grooveBand))
                    .blendMode(.screen)
                Circle()
                    .fill(AngularGradient(gradient: Gradient(stops: Self.sheen(width: 0.022, strength: 0.34)), center: .center))
                    .mask(Circle().strokeBorder(lineWidth: grooveBand))
                    .blendMode(.screen)

                Circle()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.8 * unit)

                RecordLabel(artwork: artwork, isSpinning: isSpinning, unit: unit, isStaticRender: isStaticRender)
                    .frame(width: labelDiameter, height: labelDiameter)

                Spindle()
                    .frame(width: 15 * unit, height: 15 * unit)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// Two opposed highlights, towards the light (upper left) and away from it.
    private static func sheen(width: Double, strength: Double) -> [Gradient.Stop] {
        let nearSide = 0.125, farSide = 0.625
        return [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: nearSide - width),
            .init(color: .white.opacity(strength * 0.75), location: nearSide),
            .init(color: .clear, location: nearSide + width),
            .init(color: .clear, location: farSide - width),
            .init(color: .white.opacity(strength), location: farSide),
            .init(color: .clear, location: farSide + width),
            .init(color: .clear, location: 1),
        ]
    }
}

private struct Grooves: View {
    let start: CGFloat

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2
            var random = SplitMix64(seed: 3)

            func ring(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            }

            var radius = outer * start
            while radius < outer * 0.965 {
                let brightness = Double.random(in: 0.02...0.08, using: &random)
                context.stroke(ring(radius), with: .color(.white.opacity(brightness)), lineWidth: outer * 0.0022)
                radius += outer * CGFloat.random(in: 0.0045...0.0075, using: &random)
            }

            // The silent gaps between songs.
            for gap in [0.5, 0.6, 0.69, 0.79, 0.88] as [CGFloat] {
                context.stroke(ring(outer * gap), with: .color(.black.opacity(0.7)), lineWidth: outer * 0.009)
                context.stroke(ring(outer * (gap + 0.006)), with: .color(.white.opacity(0.09)), lineWidth: outer * 0.0016)
            }
        }
    }
}

private struct RecordLabel: View {
    let artwork: NSImage?
    let isSpinning: Bool
    let unit: CGFloat
    let isStaticRender: Bool

    var body: some View {
        let image = artwork ?? DefaultLabelArt.image

        ZStack {
            if isStaticRender {
                FilledImage(image: image)
                    .clipShape(Circle())
                    .rotationEffect(.degrees(28))
            } else {
                SpinningDisc(image: image, isSpinning: isSpinning)
            }
            Circle()
                .strokeBorder(.black.opacity(0.5), lineWidth: 1.2 * unit)
            // Paper catches a little light too.
            Circle()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.16), .white.opacity(0), .black.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        }
    }
}

private struct Spindle: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color(white: 0.98), Color(white: 0.62), Color(white: 0.3)],
                center: UnitPoint(x: 0.34, y: 0.3),
                startRadius: 0,
                endRadius: 9
            ))
            .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: 0.6))
    }
}

/// The label shown when a song has no cover, or nothing is playing.
struct DefaultLabelArt: View {
    private static let cream = Color(red: 0.99, green: 0.91, blue: 0.78)

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(
                colors: [Color(red: 0.93, green: 0.44, blue: 0.20), Color(red: 0.74, green: 0.25, blue: 0.12)],
                center: .center,
                startRadius: 0,
                endRadius: 256
            ))
            Circle().strokeBorder(Self.cream.opacity(0.85), lineWidth: 3).padding(24)
            Circle().strokeBorder(Self.cream.opacity(0.45), lineWidth: 1.5).padding(38)
            Text("WAX")
                .font(.system(size: 86, weight: .heavy, design: .serif))
                .tracking(10)
                .foregroundStyle(Self.cream)
                .offset(x: 5, y: -122)
            Text("33⅓ RPM  ·  STEREO")
                .font(.system(size: 22, weight: .semibold))
                .tracking(4)
                .foregroundStyle(Self.cream.opacity(0.85))
                .offset(y: 132)
        }
        .frame(width: 512, height: 512)
    }

    @MainActor static let image: NSImage = {
        let renderer = ImageRenderer(content: DefaultLabelArt())
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: 512, height: 512))
    }()
}

// MARK: - Spinning

/// Turns the label with Core Animation, so the rotation runs in the window server and
/// costs this app nothing per frame.
struct SpinningDisc: NSViewRepresentable {
    let image: NSImage
    let isSpinning: Bool

    func makeNSView(context: Context) -> SpinningDiscView {
        SpinningDiscView()
    }

    func updateNSView(_ view: SpinningDiscView, context: Context) {
        view.image = image
        view.isSpinning = isSpinning
    }
}

final class SpinningDiscView: NSView {
    /// A true 33⅓ rpm is 1.8 seconds a turn, which reads as frantic on a label this small.
    /// This is closer to how a record feels to watch than to how fast one really goes.
    static let secondsPerTurn: CFTimeInterval = 5
    private static let spinKey = "spin"
    private static let rotation = "transform.rotation.z"

    let disc = CALayer()

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            if oldValue != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.6
                disc.add(fade, forKey: "contents")
            }
            disc.contents = image
        }
    }

    var isSpinning = false {
        didSet {
            if isSpinning != oldValue { updateSpin() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.contentsGravity = .resizeAspectFill
        disc.masksToBounds = true
        // Geometry and angle are set directly; none of it should animate implicitly.
        disc.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "transform": NSNull()]
        layer?.addSublayer(disc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = side / 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disc.contentsScale = window?.backingScaleFactor ?? 2
        // A layer loses its animations when it leaves a window.
        if window != nil { updateSpin() }
    }

    private func updateSpin() {
        if isSpinning {
            guard disc.animation(forKey: Self.spinKey) == nil else { return }
            let start = disc.value(forKeyPath: Self.rotation) as? CGFloat ?? 0
            let spin = CABasicAnimation(keyPath: Self.rotation)
            spin.fromValue = start
            // Layers measure angles anticlockwise, and records turn clockwise.
            spin.toValue = start - 2 * CGFloat.pi
            spin.duration = Self.secondsPerTurn
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            disc.add(spin, forKey: Self.spinKey)
        } else if disc.animation(forKey: Self.spinKey) != nil {
            // Stop where the record actually is, not where the animation began.
            let angle = disc.presentation()?.value(forKeyPath: Self.rotation) as? CGFloat ?? 0
            disc.removeAnimation(forKey: Self.spinKey)
            disc.setValue(angle, forKeyPath: Self.rotation)
        }
    }
}
