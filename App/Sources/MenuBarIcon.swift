import AppKit
import SwiftUI
import SyncCore

/// Two stacked drive outlines, with a badge per state (design 1a).
struct MenuBarIcon: View {
    var state: OverallState
    @Environment(\.openWindow) private var openWindow
    @State private var frame = 0
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        Image(nsImage: Self.image(for: state, frame: frame))
            .onReceive(timer) { _ in if state == .syncing { frame = (frame + 1) % 12 } }
            .onAppear { WindowOpener.action = openWindow }
            .accessibilityLabel(Self.label(state))
    }

    static func label(_ s: OverallState) -> String {
        switch s {
        case .starting: "NAS Sync: starting"
        case .upToDate: "NAS Sync: up to date"
        case .syncing: "NAS Sync: syncing"
        case .away: "NAS Sync: away from home"
        case .holdingOff: "NAS Sync: holding off"
        case .paused: "NAS Sync: paused"
        case .stale: "NAS Sync: backup is stale"
        case .error: "NAS Sync: needs attention"
        }
    }

    static func image(for state: OverallState, frame: Int) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let template = [.upToDate, .away, .holdingOff, .starting].contains(state)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink = template ? NSColor.black : NSColor.labelColor
            let dim = [.away, .holdingOff, .paused, .starting].contains(state)

            if state == .error {
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 21, height: 15), xRadius: 4, yRadius: 4).fill()
                drawGlyph(color: .white, alpha: 1)
                return true
            }
            drawGlyph(color: ink, alpha: dim ? 0.4 : 1)
            let badge = NSRect(x: 14.5, y: 0.5, width: 7.5, height: 7.5)
            if [.stale, .paused, .syncing].contains(state), let ctx = NSGraphicsContext.current {
                // Clear a thin gap around the badge so it doesn't run into the glyph.
                ctx.compositingOperation = .clear
                NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
                ctx.compositingOperation = .sourceOver
            }
            switch state {
            case .stale:
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: badge).fill()
            case .paused:
                ink.withAlphaComponent(0.6).setStroke()
                let p = NSBezierPath(ovalIn: badge.insetBy(dx: 0.75, dy: 0.75))
                p.lineWidth = 1.4
                p.stroke()
            case .syncing:
                ink.setStroke()
                let center = NSPoint(x: badge.midX, y: badge.midY)
                let start = CGFloat(frame) * -30
                let ring = NSBezierPath()
                ring.appendArc(withCenter: center, radius: 3.1, startAngle: start, endAngle: start + 270)
                ring.lineWidth = 1.5
                ring.stroke()
            default:
                break
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    private static func drawGlyph(color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setStroke()
        for y in [9.0, 3.5] {
            let r = NSBezierPath(roundedRect: NSRect(x: 3.75, y: y, width: 14.5, height: 4.5), xRadius: 1.5, yRadius: 1.5)
            r.lineWidth = 1.5
            r.stroke()
        }
    }
}
