import AppKit
import SwiftUI

/// Traffic-light status shared by the menu bar gauges and the panel bars.
enum Level: Int, Comparable {
    case ok, warn, critical

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    /// Fan speed relative to its own min...max range; a stopped fan is fine.
    static func fan(_ fraction: Double?) -> Level {
        guard let f = fraction else { return .ok }
        return f >= 0.75 ? .critical : f >= 0.5 ? .warn : .ok
    }

    static func cpu(_ percent: Double) -> Level {
        percent >= 80 ? .critical : percent >= 50 ? .warn : .ok
    }

    /// Memory pressure is what actually slows the Mac; the percentage only escalates near the top.
    static func memory(percent: Double, pressure: Int) -> Level {
        if pressure >= 4 || percent >= 90 { return .critical }
        if pressure >= 2 || percent >= 75 { return .warn }
        return .ok
    }

    var nsColor: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .warn: return .systemYellow
        case .critical: return .systemRed
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// One gauge: a ring filled to `value` (0...100), colored by `level`, with a symbol inside.
struct Gauge {
    let symbol: String
    let value: Double?          // nil = not available (no fan)
    let level: Level
    let text: String
}

extension SystemSnapshot {
    /// Fastest fan relative to its range, nil when the Mac has no readable fan.
    var fanFraction: Double? { fans.isEmpty ? nil : fans.map(\.fraction).max() }
    var fanRPM: Double { fans.map(\.rpm).max() ?? 0 }
}

enum MenuBarImage {
    private static let height: CGFloat = 20
    private static let ring: CGFloat = 17
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// Non-template image so the gauge colors survive; the drawing handler runs at draw time,
    /// so `labelColor` follows the menu bar's light/dark appearance.
    /// Current internet throughput and the last measured link capacity, all in Mbps.
    struct Net {
        let downMbps: Double
        let upMbps: Double
        let linkDownMbps: Double?
        let linkUpMbps: Double?
    }

    private static let netFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    static func make(gauges: [Gauge], net: Net?, alertCount: Int, alertLevel: Level?) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        // Fixed slot sized for the widest value ("100%") so rings never shift as numbers change.
        let slot = ring + 3 + ceil(("100%" as NSString).size(withAttributes: attrs).width)
        let widths = gauges.map { _ in slot }
        let badge: CGFloat = alertCount > 0 ? 16 : 0
        let gap: CGFloat = 7
        let netWidth = net.map { netSlotWidth(hasLink: $0.linkDownMbps != nil) } ?? 0
        let width = widths.reduce(0, +) + CGFloat(gauges.count - 1) * gap
            + (net != nil ? gap + netWidth : 0) + (badge > 0 ? gap + badge : 0)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, g) in gauges.enumerated() {
                let center = NSPoint(x: x + ring / 2, y: height / 2)
                drawRing(at: center, value: g.value, color: g.level.nsColor)
                drawSymbol(g.symbol, at: center)
                let text = g.text as NSString
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: x + ring + 3, y: (height - size.height) / 2), withAttributes: attrs)
                x += widths[i] + gap
            }
            if let net {
                drawNet(net, at: x)
                x += netWidth + gap
            }
            if alertCount > 0 {
                let rect = NSRect(x: x, y: (height - badge) / 2, width: badge, height: badge)
                (alertLevel ?? .warn).nsColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                let label = (alertCount > 9 ? "9+" : "\(alertCount)") as NSString
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                        .foregroundColor: alertLevel == .warn ? NSColor.black : NSColor.white]
                let size = label.size(withAttributes: a)
                label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: a)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Fixed width for the widest values so the gauges never shift as the numbers change.
    private static func netSlotWidth(hasLink: Bool) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: netFont]
        return ceil(((hasLink ? "↓999,9  999" : "↓999,9") as NSString).size(withAttributes: attrs).width)
    }

    static func mbps(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// Download reads green and upload red, on the arrow and on the measured capacity;
    /// the live value stays in the label color, which is the most readable on either menu bar.
    static let downColor = NSColor.systemGreen
    /// Plain system red is too dark on a black menu bar; a light coral keeps the "red = upload" reading.
    static let upColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.48, blue: 0.48, alpha: 1)   // #FF7A7A
            : .systemRed
    }

    /// Two stacked lines: "↓now" over "↑now", with the last measured capacity right-aligned.
    private static func drawNet(_ net: Net, at x: CGFloat) {
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let now: [NSAttributedString.Key: Any] = [.font: netFont, .foregroundColor: NSColor.labelColor]
        let slot = netSlotWidth(hasLink: net.linkDownMbps != nil)
        func line(_ arrow: String, _ color: NSColor, _ value: Double, _ capacity: Double?, y: CGFloat) {
            let tinted: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: color]
            let a = arrow as NSString
            a.draw(at: NSPoint(x: x, y: y), withAttributes: tinted)
            (mbps(value) as NSString).draw(at: NSPoint(x: x + a.size(withAttributes: tinted).width, y: y), withAttributes: now)
            guard let capacity else { return }
            // Right-aligned, so it stays put while the live value changes width.
            let text = "\(Int(capacity.rounded()))" as NSString
            text.draw(at: NSPoint(x: x + slot - text.size(withAttributes: tinted).width, y: y), withAttributes: tinted)
        }
        line("↓", downColor, net.downMbps, net.linkDownMbps, y: height / 2 - 0.5)
        line("↑", upColor, net.upMbps, net.linkUpMbps, y: -1)
    }

    private static func drawSymbol(_ name: String, at center: NSPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: 7.5, weight: .bold)
            .applying(.init(paletteColors: [.labelColor]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = img.size
        img.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    }

    private static func drawRing(at center: NSPoint, value: Double?, color: NSColor) {
        let radius = ring / 2 - 1.3
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.2
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()
        guard let value else { return }

        let fraction = max(0.04, min(1, value / 100))
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = 2.2
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
}

extension Monitor {
    /// Fan, CPU and memory, in that order, shared by the menu bar and the widget.
    var gauges: [Gauge] {
        let s = snapshot
        let fan = s.fanFraction
        return [
            Gauge(symbol: "fan.fill", value: fan.map { $0 * 100 }, level: .fan(fan),
                  text: fan.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"),
            Gauge(symbol: "cpu", value: s.cpuTotal, level: .cpu(s.cpuTotal), text: "\(Int(s.cpuTotal.rounded()))%"),
            Gauge(symbol: "memorychip", value: memoryPercent, level: memoryLevel, text: "\(Int(memoryPercent.rounded()))%"),
        ]
    }

    var menuBarNet: MenuBarImage.Net {
        MenuBarImage.Net(downMbps: snapshot.netInRate * 8 / 1_000_000, upMbps: snapshot.netOutRate * 8 / 1_000_000,
                         linkDownMbps: speed?.downMbps, linkUpMbps: speed?.upMbps)
    }
}
