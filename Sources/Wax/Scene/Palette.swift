import AppKit
import SwiftUI

/// Colours taken from the cover, so the window tints to match the record.
struct Palette: Equatable {
    /// Darkest tone, at the edges.
    var deep: Color
    /// The main field.
    var mid: Color
    /// The pool of light behind the deck.
    var glow: Color

    /// Warm umber, used when nothing is playing.
    static let idle = Palette(hue: 0.065, saturation: 0.42)

    init(hue: Double, saturation: Double) {
        let s = min(max(saturation, 0), 1)
        deep = Color(hue: hue, saturation: min(0.75, s * 1.05), brightness: 0.075)
        mid = Color(hue: hue, saturation: min(0.65, s * 0.9), brightness: 0.16)
        glow = Color(hue: hue, saturation: min(0.55, s * 0.75), brightness: 0.36)
    }

    init(image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            self = .idle
            return
        }

        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.interpolationQuality = .medium
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        // Average the hues as vectors, weighted towards vivid pixels. A plain RGB average
        // turns any busy cover into brown.
        var x = 0.0, y = 0.0, weight = 0.0, saturationSum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            let delta = high - low
            guard delta > 0.05 else { continue }

            var hue: Double
            if high == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if high == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }

            let saturation = delta / high
            let w = saturation * saturation * (0.3 + high)
            x += cos(2 * .pi * hue) * w
            y += sin(2 * .pi * hue) * w
            weight += w
            saturationSum += saturation * w
        }

        // Near-monochrome cover: a neutral backdrop beats an arbitrary hue.
        guard weight > Double(side * side) * 0.01 else {
            self.init(hue: 0.08, saturation: 0.07)
            return
        }

        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        // Hues that disagree cancel out; mute the result in proportion.
        let agreement = hypot(x, y) / weight
        self.init(hue: hue, saturation: saturationSum / weight * (0.35 + 0.65 * agreement))
    }
}

/// Deterministic random numbers, so procedural textures look the same on every launch.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// An image scaled to fill its frame exactly, cropping the overflow.
struct FilledImage: View {
    let image: NSImage

    var body: some View {
        Color.clear
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
            .clipped()
    }
}
