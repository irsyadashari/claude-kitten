import AppKit
import SwiftUI

/// Where settings live. The demo swaps in its own store so it never touches the user's settings.
enum KittenSettings {
    static var store: UserDefaults = .standard
}

let claudeOrange = Color(.sRGB, red: 0.851, green: 0.467, blue: 0.341, opacity: 1)
let bubbleInk = Color(.sRGB, red: 0.27, green: 0.15, blue: 0.11, opacity: 1)
let bubbleCream = Color(.sRGB, red: 1.0, green: 0.976, blue: 0.95, opacity: 1)

final class KittenModel: ObservableObject {
    @Published var nudges: [Nudge] = []
    @Published var risen = false
    @Published var bubble = false
    @Published var waving = false
    @Published var held = false
    @Published var bumpAt = Date.distantPast
    @Published var restMood: KittenMood = .sleepy
    @Published var bubbleOnLeft = true
    @Published var bubbleBelow = false
    @Published var hint = "Click me for your sessions"
    @Published var side: CGFloat = KittenController.kittenSize.width

    var mood: KittenMood {
        if nudges.isEmpty { return restMood }
        let alert = nudges.contains {
            switch $0.kind {
            case .needsYou, .error, .meow(ok: false): return true
            default: return false
            }
        }
        return alert ? .alert : .happy
    }
}

// MARK: - Window

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the kitten's little window: where it sits, when it shows, and its speech bubble.
/// The window is only as big as the kitten while resting, and grows to fit the bubble during a nudge.
final class KittenController {
    /// Pixel scale options: whole numbers keep the pixel art crisp.
    static let sizes: [(label: String, scale: Int)] = [("Tiny", 2), ("Small", 3), ("Medium", 4), ("Big", 5), ("Huge", 6)]
    static var scale: Int {
        let v = KittenSettings.store.integer(forKey: "kittenScale")
        return (2...6).contains(v) ? v : 4
    }
    static var kittenSize: NSSize {
        let side = CGFloat(KittenScene.width * scale)
        return NSSize(width: side, height: side)
    }
    static let bubbleArea = NSSize(width: 320, height: 210)

    let model = KittenModel()
    var onTap: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onRenudge: ((Int) -> Void)?

    /// A nudge (speech bubble) is showing.
    private(set) var isNudging = false
    /// The kitten is on screen at all.
    private(set) var isVisible = false

    private let panel: OverlayPanel
    private var anchor: NSPoint = .zero // bottom-left of the kitten, in screen coordinates
    private var dragStart: (mouse: NSPoint, anchor: NSPoint)?
    private var renudgeTimer: Timer?
    private var renudgeCount = 0

    private var alwaysVisible: Bool { KittenSettings.store.bool(forKey: "alwaysVisible") }

    init() {
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.kittenSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = KittenOverlay(model: model,
                                 onTap: { [weak self] in self?.onTap?() },
                                 onDismiss: { [weak self] in self?.onDismiss?() },
                                 onDrag: { [weak self] in self?.dragChanged() },
                                 onDragEnd: { [weak self] in self?.dragEnded() })
        let host = ClickThroughHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
        anchor = Self.savedAnchor() ?? Self.defaultAnchor()
    }

    var kittenFrame: NSRect { NSRect(origin: anchor, size: Self.kittenSize) }

    // MARK: Showing and hiding

    /// Call after the "always show kitten" setting changes.
    func applyVisibilityPreference() {
        if alwaysVisible { appear() } else if !isNudging { disappear() }
    }

    func setRestMood(_ mood: KittenMood, hint: String) {
        if model.restMood != mood { model.restMood = mood }
        if model.hint != hint { model.hint = hint }
    }

    func show(_ nudges: [Nudge]) {
        model.nudges = nudges
        if isNudging && model.bubble { bump(); return }
        isNudging = true
        let fresh = !isVisible
        model.waving = false
        appear()
        layoutWindow(bubble: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + (fresh ? 0.45 : 0.05)) {
            guard self.isNudging else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { self.model.bubble = true }
            self.bump()
        }
        startRenudge()
    }

    func update(_ nudges: [Nudge]) { model.nudges = nudges }

    func bump() { model.bumpAt = Date() }

    /// Ends the nudge: the bubble goes away, and the kitten either rests or leaves.
    func settle(wave: Bool) {
        guard isNudging else { return }
        isNudging = false
        renudgeTimer?.invalidate()
        withAnimation(.easeOut(duration: 0.2)) { model.bubble = false }
        if wave { model.waving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !self.isNudging else { return }
            self.model.nudges = []
            self.layoutWindow(bubble: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wave ? 1.1 : 0.3)) {
            guard !self.isNudging else { return }
            self.model.waving = false
            if !self.alwaysVisible { self.disappear() }
        }
    }

    private func appear() {
        guard !isVisible else { return }
        isVisible = true
        clampAnchor()
        layoutWindow(bubble: false)
        model.risen = false
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { self.model.risen = true }
        }
    }

    private func disappear() {
        guard isVisible else { return }
        isVisible = false
        withAnimation(.easeIn(duration: 0.25)) { model.risen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !self.isVisible else { return }
            self.panel.orderOut(nil)
        }
    }

    // MARK: Position

    static func defaultAnchor() -> NSPoint {
        let vf = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        return NSPoint(x: vf.maxX - kittenSize.width - 10, y: vf.minY)
    }

    private static func savedAnchor() -> NSPoint? {
        let d = KittenSettings.store
        guard d.object(forKey: "kittenX") != nil else { return nil }
        return NSPoint(x: d.double(forKey: "kittenX"), y: d.double(forKey: "kittenY"))
    }

    private func saveAnchor() {
        KittenSettings.store.set(anchor.x, forKey: "kittenX")
        KittenSettings.store.set(anchor.y, forKey: "kittenY")
    }

    private func screen(for p: NSPoint) -> NSScreen? {
        let c = NSPoint(x: p.x + Self.kittenSize.width / 2, y: p.y + Self.kittenSize.height / 2)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.screens.first
    }

    /// Keeps the kitten fully on a screen (e.g. after unplugging a display).
    private func clampAnchor() {
        guard let vf = screen(for: anchor)?.visibleFrame else { return }
        anchor.x = min(max(anchor.x, vf.minX), vf.maxX - Self.kittenSize.width)
        anchor.y = min(max(anchor.y, vf.minY), vf.maxY - Self.kittenSize.height)
    }

    func reposition() {
        clampAnchor()
        layoutWindow()
    }

    /// Call after the size setting changes. Keeps the kitten's bottom-center where it was.
    func applySize() {
        let old = model.side
        let new = Self.kittenSize.width
        guard old != new else { return }
        anchor.x += (old - new) / 2
        model.side = new
        clampAnchor()
        layoutWindow()
        saveAnchor()
        bump()
    }

    func resetPosition() {
        anchor = Self.defaultAnchor()
        saveAnchor()
        layoutWindow()
    }

    private func layoutWindow(bubble: Bool? = nil) {
        let withBubble = bubble ?? (isNudging || model.bubble)
        var f = kittenFrame
        if withBubble {
            if dragStart == nil, let vf = screen(for: anchor)?.visibleFrame {
                model.bubbleOnLeft = anchor.x + Self.kittenSize.width / 2 > vf.midX
                model.bubbleBelow = anchor.y + Self.bubbleArea.height > vf.maxY
            }
            f.size = NSSize(width: Self.kittenSize.width + Self.bubbleArea.width, height: Self.bubbleArea.height)
            if model.bubbleOnLeft { f.origin.x -= Self.bubbleArea.width }
            if model.bubbleBelow { f.origin.y = anchor.y + Self.kittenSize.height - Self.bubbleArea.height }
        }
        panel.setFrame(f, display: true)
    }

    /// Demo only: move the kitten as if it were being carried.
    func demoPlace(_ p: NSPoint, held: Bool) {
        anchor = p
        model.held = held
        layoutWindow()
    }

    // MARK: Dragging

    private func dragChanged() {
        let m = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (m, anchor)
            model.held = true
        }
        guard let s = dragStart else { return }
        anchor = NSPoint(x: s.anchor.x + m.x - s.mouse.x, y: s.anchor.y + m.y - s.mouse.y)
        layoutWindow()
    }

    private func dragEnded() {
        dragStart = nil
        model.held = false
        clampAnchor()
        layoutWindow()
        saveAnchor()
    }

    private func startRenudge() {
        renudgeTimer?.invalidate()
        renudgeCount = 0
        let t = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            guard let self, self.isNudging else { return }
            self.renudgeCount += 1
            self.onRenudge?(self.renudgeCount)
        }
        RunLoop.main.add(t, forMode: .common)
        renudgeTimer = t
    }
}

// MARK: - Views

struct KittenOverlay: View {
    @ObservedObject var model: KittenModel
    let onTap: () -> Void
    let onDismiss: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    var body: some View {
        HStack(alignment: model.bubbleBelow ? .top : .bottom, spacing: -2) {
            if model.bubbleOnLeft { bubble; kitten } else { kitten; bubble }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: Alignment(horizontal: model.bubbleOnLeft ? .trailing : .leading,
                                    vertical: model.bubbleBelow ? .top : .bottom))
    }

    @ViewBuilder private var bubble: some View {
        if model.bubble {
            SpeechBubble(nudges: model.nudges, tailOnRight: model.bubbleOnLeft, tailNearTop: model.bubbleBelow,
                         onDismiss: onDismiss)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .padding(model.bubbleBelow ? .top : .bottom, bubbleOffset)
                .transition(.scale(scale: 0.2, anchor: model.bubbleOnLeft ? .bottomTrailing : .bottomLeading)
                    .combined(with: .opacity))
        }
    }

    /// Lines the bubble's tail up with the kitten's face at any size.
    private var bubbleOffset: CGFloat {
        model.bubbleBelow ? max(0, model.side * 0.54 - 44) : max(0, model.side * 0.46 - 30)
    }

    private var kitten: some View {
        KittenSpriteView(model: model)
            .frame(width: model.side, height: model.side)
            .scaleEffect(model.risen ? 1 : 0.15, anchor: .bottom)
            .opacity(model.risen ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in onDrag() }
                    .onEnded { _ in onDragEnd() }
            )
            .help(model.hint)
    }
}

struct KittenSpriteView: View {
    @ObservedObject var model: KittenModel
    var fixedTime: Double? = nil

    var body: some View {
        if let t = fixedTime {
            canvas(t: t, now: Date(timeIntervalSinceReferenceDate: t))
        } else {
            // Calm frame rate while resting, smooth while nudging or being carried.
            let busy = !model.nudges.isEmpty || model.held || model.waving
            TimelineView(.animation(minimumInterval: busy ? 1.0 / 30 : 1.0 / 12,
                                    paused: !(model.risen || model.waving))) { tl in
                canvas(t: tl.date.timeIntervalSinceReferenceDate, now: tl.date)
            }
        }
    }

    private func canvas(t: Double, now: Date) -> some View {
        let mood = model.mood
        let bumpAge = now.timeIntervalSince(model.bumpAt)
        let waving = model.waving
        let held = model.held
        return Canvas { ctx, size in
            let s = floor(size.width / CGFloat(KittenScene.width))
            for layer in KittenScene.compose(t: t, mood: mood, bumpAge: bumpAge, waving: waving, held: held) {
                PixelPainter.paint(layer, scale: s, in: &ctx)
            }
        }
    }
}

/// A small looping kitten for the sessions panel.
struct MiniKitten: View {
    var mood: KittenMood
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { tl in
            Canvas { ctx, size in
                let s = floor(size.width / CGFloat(KittenScene.width))
                for layer in KittenScene.compose(t: tl.date.timeIntervalSinceReferenceDate, mood: mood, bumpAge: -1, waving: false) {
                    PixelPainter.paint(layer, scale: s, in: &ctx)
                }
            }
        }
    }
}

struct SpeechBubble: View {
    let nudges: [Nudge]
    var tailOnRight = true
    var tailNearTop = false
    let onDismiss: () -> Void

    var body: some View {
        let c = BubbleText.make(nudges)
        VStack(alignment: .leading, spacing: 5) {
            Text(c.title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(bubbleInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let d = c.detail {
                Text(d)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(bubbleInk.opacity(0.78))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                if let f = c.foot { Text(f); Text("·") }
                Text("tap me for all sessions 🐾")
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundColor(bubbleInk.opacity(0.5))
            .lineLimit(1)
        }
        .padding(.leading, tailOnRight ? 14 : 24)
        .padding(.trailing, tailOnRight ? 24 : 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 290, alignment: .leading)
        .background(
            ZStack {
                BubbleShape(tailOnRight: tailOnRight, tailNearTop: tailNearTop).stroke(claudeOrange, lineWidth: 5)
                BubbleShape(tailOnRight: tailOnRight, tailNearTop: tailNearTop).fill(bubbleCream)
            }
            .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
        )
        .overlay(alignment: tailOnRight ? .topLeading : .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(claudeOrange))
            }
            .buttonStyle(.plain)
            .offset(x: tailOnRight ? -5 : 5, y: -5)
            .help("Dismiss")
        }
        .padding(10)
    }
}

/// Rounded bubble with a little tail pointing toward the kitten.
struct BubbleShape: Shape {
    var tailOnRight = true
    var tailNearTop = false

    func path(in r: CGRect) -> Path {
        let tail: CGFloat = 11
        let body = CGRect(x: r.minX, y: r.minY, width: r.width - tail, height: r.height)
        var p = Path(roundedRect: body, cornerRadius: 15, style: .continuous)
        let ty = tailNearTop ? body.minY + 34 : body.maxY - 20
        p.move(to: CGPoint(x: body.maxX - 2, y: ty - 9))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: ty + 6), control: CGPoint(x: body.maxX + 3, y: ty + 1))
        p.addQuadCurve(to: CGPoint(x: body.maxX - 2, y: ty + 5), control: CGPoint(x: body.maxX + 2, y: ty + 6))
        p.closeSubpath()
        if tailOnRight { return p }
        return p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: r.minX + r.maxX, ty: 0))
    }
}

struct BubbleText {
    var title: String
    var detail: String?
    var foot: String?

    static func make(_ nudges: [Nudge]) -> BubbleText {
        guard let n = nudges.last else { return BubbleText(title: "Meow~") }
        if nudges.count > 1 {
            let lines = nudges.suffix(3).reversed().map { m -> String in
                switch m.kind {
                case .needsYou: return "👀  \(m.name) needs you"
                case .error: return "🙀  \(m.name) hit a snag"
                case .meow: return "🐾  \(m.detail ?? m.name)"
                case .done: return "✨  \(m.name) is done"
                }
            }
            let more = nudges.count > 3 ? "\n…and \(nudges.count - 3) more" : ""
            return BubbleText(title: "Mrrp! \(nudges.count) things for you 🐾",
                              detail: lines.joined(separator: "\n") + more)
        }
        let greets = ["Meow~", "Mrrp!", "Nya~", "Purr…"]
        let greet = greets[abs(n.id.hashValue ^ Int(n.at.timeIntervalSince1970)) % greets.count]
        switch n.kind {
        case .done:
            return BubbleText(title: "\(greet) \(n.name) is done! ✨", detail: n.detail, foot: n.footnote)
        case .needsYou:
            return BubbleText(title: "Psst! \(n.name) needs you 👀", detail: n.detail)
        case .error:
            return BubbleText(title: "Uh oh… \(n.name) hit a snag 🙀", detail: n.detail)
        case .meow(let ok):
            let title = ok == false ? "Hmm, something failed 🙀" : "\(greet) Your shell is done! 🐾"
            return BubbleText(title: title, detail: n.detail, foot: n.name)
        }
    }
}

