import AppKit
import SwiftUI

// Pixel-art kitten in Claude orange. Each character in a sprite row is one pixel.

struct RGB {
    let r, g, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

enum Palette {
    static let map: [Character: RGB] = [
        "d": RGB(0x5C2D1F), // outline
        "o": RGB(0xD97757), // Claude orange fur
        "s": RGB(0xC0603F), // fur shade
        "p": RGB(0xF4A0A6), // pink ears, cheeks, nose
        "k": RGB(0x23150F), // eyes
        "w": RGB(0xFFFFFF), // eye shine
        "l": RGB(0xF8D5C3), // light paws
        "h": RGB(0xFF5C86), // heart
        "H": RGB(0xFFC2D2), // heart shine
        "y": RGB(0xFFC83A), // exclamation
        "z": RGB(0x8A7CA8), // sleepy z
        "B": RGB(0x7A5532), // box outline
        "b": RGB(0xC99A62), // box front
        "c": RGB(0xE3BE88), // box rim
        "t": RGB(0xB3874F), // box tape
    ]
}

typealias Pixels = [[Character]]

struct PixelLayer {
    var rows: Pixels
    var x: Double
    var y: Double
    var opacity: Double = 1
}

enum Sprites {
    /// Builds a symmetric sprite from its left half.
    static func mirrored(_ halves: [String]) -> Pixels {
        halves.map { let a = Array($0); return a + a.reversed() }
    }

    static let headBase: Pixels = {
        var r = mirrored([
            "..dd.....",
            ".dood....",
            ".dopod...",
            ".doppoddd",
            "doooooooo",
            "doooooooo",
            "doookkooo",
            "doookkooo",
            "doppoooop",
            "dooooooko",
            ".dooooook",
            "..ddddddd",
        ])
        r[6][4] = "w"
        r[6][12] = "w"
        return r
    }()

    static func head(blink: Bool, twitch: Bool) -> Pixels {
        var r = headBase
        if blink {
            for x in [4, 5, 12, 13] { r[6][x] = "o" }
        }
        if twitch {
            r[0] = Array(".dd...........dd..")
            r[1] = Array("dood.........dood.")
        }
        return r
    }

    static let body: Pixels = Array(repeating: Array("..d" + String(repeating: "o", count: 12) + "d.."), count: 12)

    static let paw: Pixels = ["dllld", "dldld", ".ddd."].map { Array($0) }
    static let heart: Pixels = ["Hh.hh", "hhhhh", ".hhh.", "..h.."].map { Array($0) }
    static let bang: Pixels = [".ddd.", ".dyd.", ".dyd.", ".dyd.", "..d..", ".....", ".dyd.", "..d.."].map { Array($0) }
    static let box: Pixels = mirrored([
        "BBB..........",
        "BccBB........",
        ".BBBBBBBBBBBB",
        "..Bcccccccccc",
        "..Bbbbbbbbbbt",
        "..Bbbbbbbbbbt",
        "..Bbbbbbbbbbt",
        "..Bbbbbbbbbbt",
    ])
    static let zee: Pixels = ["zzz", "..z", ".z.", "zzz"].map { Array($0) }
}

enum KittenMood { case happy, alert, sleepy, working, plain }

/// The animated kitten scene, as pixel layers for a given moment.
/// The kitten peeks out of a little cardboard box, so it looks at home anywhere on screen.
enum KittenScene {
    static let width = 26
    static let height = 26
    static let ox = 4.0
    static let oy = 8.0

    static func compose(t: Double, mood: KittenMood, bumpAge: Double, waving: Bool, held: Bool = false) -> [PixelLayer] {
        var layers: [PixelLayer] = []

        // Breathing bob, plus a bouncy hop when nudging.
        var lift = sin(t * 2.0) > 0.55 ? 1.0 : 0.0
        if bumpAge >= 0 && bumpAge < 1.5 {
            let decay = 1 - bumpAge / 1.5
            lift += (abs(sin(bumpAge * .pi * 2.4)) * 5 * decay).rounded()
        }
        if held { lift = 3 }
        let y = oy - lift

        let blink = !held && (mood == .sleepy || t.truncatingRemainder(dividingBy: 3.8) < 0.15)
        let twitch = (t + 1.3).truncatingRemainder(dividingBy: 6.1) < 0.28

        // Paw taps: a little knead every few seconds; steady kneading while Claude works.
        var leftUp = 0.0, rightUp = 0.0, rightDX = 0.0
        let tapEvery: Double = mood == .working ? 1.0 : (mood == .alert ? 2.2 : 4.0)
        let phase = t.truncatingRemainder(dividingBy: tapEvery)
        if bumpAge >= 0 && bumpAge < 1.5 {
            if Int(bumpAge / 0.13) % 2 == 0 { leftUp = 3 } else { rightUp = 3 }
        } else if mood != .sleepy && phase < 0.8 {
            if Int(phase / 0.2) % 2 == 0 { leftUp = 2 } else { rightUp = 2 }
        }
        if waving {
            leftUp = 0
            rightUp = 8
            rightDX = Int(t / 0.16) % 2 == 0 ? 3 : 5
        }
        if held { // dangling paws, like being picked up
            leftUp = -1
            rightUp = -1
        }

        layers.append(PixelLayer(rows: Sprites.body, x: ox, y: y + 10))
        layers.append(PixelLayer(rows: Sprites.head(blink: blink, twitch: twitch), x: ox, y: y))
        layers.append(PixelLayer(rows: Sprites.box, x: 0, y: 18))
        layers.append(PixelLayer(rows: Sprites.paw, x: ox + 2, y: oy + 11 - leftUp - lift))
        layers.append(PixelLayer(rows: Sprites.paw, x: ox + 11 + rightDX, y: oy + 11 - rightUp - lift))

        switch mood {
        case .happy:
            for i in 0..<3 {
                let ph = (t * 0.32 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let hx = ox + 1 + Double(i) * 6 + sin(ph * 5 + Double(i) * 2) * 1.3
                let hy = y - 4 - ph * 9
                let fade = ph < 0.15 ? ph / 0.15 : max(0, 1 - (ph - 0.15) / 0.85)
                layers.append(PixelLayer(rows: Sprites.heart, x: hx, y: hy, opacity: fade))
            }
        case .alert:
            let hop = sin(t * 9) > 0 ? 0.0 : 1.0
            layers.append(PixelLayer(rows: Sprites.bang, x: ox + 16, y: max(0, y - 8 - hop)))
        case .sleepy:
            let ph = (t * 0.25).truncatingRemainder(dividingBy: 1)
            layers.append(PixelLayer(rows: Sprites.zee, x: ox + 15 + ph * 3, y: y - 4 - ph * 6,
                                     opacity: max(0, 1 - ph)))
        case .working, .plain:
            break
        }
        return layers
    }
}

enum PixelPainter {
    static func paint(_ layer: PixelLayer, scale s: CGFloat, in ctx: inout GraphicsContext) {
        guard layer.opacity > 0.01 else { return }
        let ox = CGFloat(layer.x.rounded()), oy = CGFloat(layer.y.rounded())
        for (j, row) in layer.rows.enumerated() {
            for (i, c) in row.enumerated() where c != "." {
                guard let rgb = Palette.map[c] else { continue }
                let rect = CGRect(x: (ox + CGFloat(i)) * s, y: (oy + CGFloat(j)) * s, width: s, height: s)
                ctx.fill(Path(rect), with: .color(rgb.color.opacity(layer.opacity)))
            }
        }
    }

    /// Paints into a CoreGraphics context whose origin is bottom-left.
    static func paint(_ layer: PixelLayer, scale s: CGFloat, canvasHeight h: CGFloat, offset: CGPoint = .zero, in ctx: CGContext) {
        guard layer.opacity > 0.01 else { return }
        let ox = CGFloat(layer.x.rounded()), oy = CGFloat(layer.y.rounded())
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setAlpha(layer.opacity)
        for (j, row) in layer.rows.enumerated() {
            for (i, c) in row.enumerated() where c != "." {
                guard let rgb = Palette.map[c] else { continue }
                ctx.setFillColor(rgb.cg)
                let x = offset.x + (ox + CGFloat(i)) * s
                let y = h - offset.y - (oy + CGFloat(j) + 1) * s
                ctx.fill(CGRect(x: x, y: y, width: s, height: s))
            }
        }
        ctx.restoreGState()
    }

    /// Small kitten face for the menu bar and the panel header.
    static func faceImage(blink: Bool, badge: Bool, scale: CGFloat = 1) -> NSImage {
        let layers = [
            PixelLayer(rows: Sprites.head(blink: blink, twitch: false), x: 0, y: 0),
            PixelLayer(rows: Sprites.paw, x: 2, y: 11),
            PixelLayer(rows: Sprites.paw, x: 11, y: 11),
        ]
        let w: CGFloat = 20, h: CGFloat = 14
        let img = NSImage(size: NSSize(width: w * scale, height: h * scale), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            for l in layers { paint(l, scale: scale, canvasHeight: h * scale, in: ctx) }
            if badge {
                ctx.setFillColor(Palette.map["h"]!.cg)
                ctx.fillEllipse(in: CGRect(x: (w - 5) * scale, y: (h - 5) * scale, width: 5 * scale, height: 5 * scale))
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
