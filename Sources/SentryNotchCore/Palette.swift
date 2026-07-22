import Foundation

/// A colour pulled out of album artwork, in 0...1 sRGB.
public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// Perceived brightness (Rec. 601). Used to keep extracted colours legible
    /// against a near-black panel.
    public var luma: Double { 0.299 * r + 0.587 * g + 0.114 * b }
}

/// Hue/saturation/lightness, the space the picking actually happens in.
/// Artwork is chosen by designers for its colour, so hue is the signal; RGB
/// averaging across an image just converges on grey.
public func toHSL(_ c: RGB) -> (h: Double, s: Double, l: Double) {
    let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
    let l = (mx + mn) / 2
    guard mx > mn else { return (0, 0, l) }
    let d = mx - mn
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    var h: Double
    switch mx {
    case c.r: h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0)
    case c.g: h = (c.b - c.r) / d + 2
    default:  h = (c.r - c.g) / d + 4
    }
    return (h / 6, s, l)
}

public func fromHSL(h: Double, s: Double, l: Double) -> RGB {
    guard s > 0 else { return RGB(r: l, g: l, b: l) }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    func channel(_ t0: Double) -> Double {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
    return RGB(r: channel(h + 1.0 / 3), g: channel(h), b: channel(h - 1.0 / 3))
}

/// Pick one accent colour to represent an image.
///
/// Two properties matter more than fidelity, because the result is used as a
/// UI tint on a near-black panel rather than as a swatch:
///
/// - **It is never mud.** Averaging pixels converges on grey, and a grey accent
///   makes the whole widget look broken. Samples are bucketed by hue and the
///   winning bucket is chosen by colourfulness, not by area — so a mostly-black
///   sleeve with one red stripe returns red, which is what a person would say
///   the cover's colour is.
/// - **It is always legible.** Saturation and lightness are clamped into a band
///   that stays readable on the panel, so a near-white or near-black cover still
///   yields a usable tint instead of vanishing into the background.
///
/// Achromatic images have no hue to find; those return a neutral and the caller
/// is expected to fall back to the user's own accent.
public func pickAccent(from samples: [RGB]) -> RGB? {
    guard !samples.isEmpty else { return nil }

    // 24 buckets ≈ 15° each: wide enough that dithering and JPEG noise stay
    // together, narrow enough to keep red and orange apart.
    let buckets = 24
    var weight = [Double](repeating: 0, count: buckets)
    // Hue is circular, so it is summed as unit vectors — a plain mean of 0.99
    // and 0.01 gives 0.5 (cyan) when the answer is red.
    var sumX = [Double](repeating: 0, count: buckets)
    var sumY = [Double](repeating: 0, count: buckets)
    var sumS = [Double](repeating: 0, count: buckets)
    var sumL = [Double](repeating: 0, count: buckets)

    for c in samples {
        let (h, s, l) = toHSL(c)
        // Near-black and near-white pixels carry no usable hue; letting them
        // vote is exactly what drags the result toward grey.
        guard s > 0.15, l > 0.12, l < 0.92 else { continue }
        // Weight by colourfulness, and prefer mid lightness — the tones that
        // survive being used as a tint.
        let w = s * (1 - abs(l - 0.5) * 1.2)
        guard w > 0 else { continue }
        let i = min(buckets - 1, Int(h * Double(buckets)))
        let angle = h * 2 * .pi
        weight[i] += w
        sumX[i] += cos(angle) * w
        sumY[i] += sin(angle) * w
        sumS[i] += s * w
        sumL[i] += l * w
    }

    guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
          weight[best] > 0 else { return nil }

    let w = weight[best]
    var h = atan2(sumY[best] / w, sumX[best] / w) / (2 * .pi)
    if h < 0 { h += 1 }
    let s = min(1, max(0.55, sumS[best] / w * 1.25))   // push toward vivid
    let l = min(0.68, max(0.46, sumL[best] / w))       // keep it readable
    return fromHSL(h: h, s: s, l: l)
}
