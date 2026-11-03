import AppKit
import SwiftUI

enum Render {
    static func png(width: Int, height: Int, _ draw: (CGContext) -> Void) -> Data? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func icon(_ ctx: CGContext, size: CGFloat) {
        let inset = size * 0.09
        let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let path = CGPath(roundedRect: rect, cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = [RGB(0xFFF4EA).cg, RGB(0xF9D9C6).cg] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        }
        let s = rect.width / CGFloat(KittenScene.width)
        for layer in KittenScene.compose(t: 1.0, mood: .happy, bumpAge: -1, waving: false) where layer.opacity > 0.5 {
            PixelPainter.paint(layer, scale: s, canvasHeight: size, offset: CGPoint(x: rect.minX, y: inset), in: ctx)
        }
        ctx.restoreGState()
    }

    static func iconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(Int, String)] = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                                      (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                                      (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
        for (px, name) in sizes {
            if let data = png(width: px, height: px, { icon($0, size: CGFloat(px)) }) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
            }
        }
    }

    /// A strip of animation frames, for checking the sprite.
    static func preview(to path: String) {
        let frames: [(Double, KittenMood, Double, Bool, Bool)] = [
            (1.0, .plain, -1, false, false), (0.05, .plain, -1, false, false), (0.1, .happy, 0.2, false, false),
            (2.0, .alert, -1, false, false), (1.0, .sleepy, -1, false, false), (1.0, .plain, -1, true, false),
            (1.0, .working, -1, false, true),
        ]
        let s: CGFloat = 8
        let fw = CGFloat(KittenScene.width) * s, fh = CGFloat(KittenScene.height) * s
        let w = Int(fw) * frames.count + 10 * frames.count, h = Int(fh)
        let data = png(width: w, height: h) { ctx in
            ctx.setFillColor(RGB(0xEDEDED).cg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for (i, f) in frames.enumerated() {
                let off = CGPoint(x: CGFloat(i) * (fw + 10), y: 0)
                ctx.setFillColor(RGB(0xFFFFFF).cg)
                ctx.fill(CGRect(x: off.x, y: 0, width: fw, height: fh))
                for l in KittenScene.compose(t: f.0, mood: f.1, bumpAge: f.2, waving: f.3, held: f.4) {
                    PixelPainter.paint(l, scale: s, canvasHeight: fh, offset: off, in: ctx)
                }
            }
        }
        try? data?.write(to: URL(fileURLWithPath: path))
    }

    /// Renders the real bubble + kitten overlay, for checking the layout.
    @MainActor static func overlayPreview(to path: String) {
        let model = KittenModel()
        model.risen = true
        model.bubble = true
        model.nudges = [Nudge(id: "x", kind: .done, name: "my-app",
                              detail: "All 42 tests pass and the build is green. I also cleaned up the unused imports.",
                              footnote: "took 3m 12s", at: Date(), sessionKey: nil)]
        let view = HStack(alignment: .bottom, spacing: -4) {
            SpeechBubble(nudges: model.nudges, onDismiss: {}).padding(.bottom, 20)
            KittenSpriteView(model: model, fixedTime: 1.0).frame(width: 104, height: 104)
        }
        .padding(20)
        .background(Color(white: 0.35))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

let argv = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
if let dir = argValue("--render-iconset") { Render.iconset(to: dir); exit(0) }
if argv.contains("--dump-sessions") {
    let store = SessionStore()
    store.refresh()
    for s in store.sessions {
        print("\(s.id)  [\(s.state.rawValue)]  \(s.name)  ·  \(s.activity)  ·  since \(formatDuration(Date().timeIntervalSince1970 - s.since))  ·  hook=\(s.hook != nil)  app=\(HostApp.find(for: s)?.localizedName ?? "-")")
    }
    exit(0)
}
if let p = argValue("--preview") { Render.preview(to: p); exit(0) }
if let p = argValue("--preview-panel") {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        let store = SessionStore()
        store.refresh()
        let view = SessionsView(store: store, ui: PanelUI(), actions: { PanelActions() })
            .background(Color(white: 0.96))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: p))
        }
    }
    exit(0)
}
if let p = argValue("--preview-overlay") {
    _ = NSApplication.shared
    MainActor.assumeIsolated { Render.overlayPreview(to: p) }
    exit(0)
}

if argv.contains("--demo") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let out = argValue("--demo").flatMap { $0.hasPrefix("-") ? nil : $0 }
    let director = DemoDirector()
    director.start(recordTo: out)
    app.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
