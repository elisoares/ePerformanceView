import AppKit
import SwiftUI

/// Borderless window pinned to the desktop layer: stays under normal windows,
/// on every Space, and can be dragged anywhere (position is remembered).
@MainActor
final class DesktopWidgetController {
    static let size = NSSize(width: 703, height: 150)
    private var window: NSPanel?
    private let frameKey = "MonitorLeveDesktopWidgetMatrix"

    func show(monitor: Monitor) {
        if let window { window.orderFront(nil); return }
        let host = NSHostingView(rootView: MatrixWidgetView().environmentObject(monitor))
        host.frame.size = Self.size
        host.sizingOptions = []   // fixed size: don't re-run window layout on every update

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if panel.setFrameUsingName(frameKey) {
            // Keep the saved top-left corner but always use the current widget size.
            let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(Self.size)
            panel.setFrameTopLeftPoint(top)
        } else if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.midX - Self.size.width / 2, y: screen.maxY - 40))
        }
        panel.setFrameAutosaveName(frameKey)
        panel.orderFront(nil)
        window = panel
    }

    func hide() {
        window?.saveFrame(usingName: frameKey)
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Matrix theme

enum MatrixTheme {
    static let green = Color(red: 0, green: 1, blue: 0.255)            // #00FF41
    static let dim = Color(red: 0, green: 0.56, blue: 0.067)           // #008F11
    static let bright = Color(red: 0.71, green: 1, blue: 0.78)         // #B6FFC8
    static let warn = Color(red: 0.83, green: 1, blue: 0.23)           // #D4FF3A
    static let critical = Color(red: 1, green: 0.23, blue: 0.23)       // #FF3B3B
    static let cold = Color(red: 0.24, green: 0.72, blue: 1)            // #3DB8FF

    static func color(_ level: Level) -> Color {
        switch level {
        case .ok: return green
        case .warn: return warn
        case .critical: return critical
        }
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct MatrixWidgetView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var confirmKill = false

    var body: some View {
        let s = monitor.snapshot
        ZStack {
            // Transparent: the desktop shows through. A near-invisible fill keeps the whole area draggable.
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.001))
            HStack(spacing: 0) {
                gauges(s).frame(width: 254)
                divider
                cores(s).padding(.horizontal, 8).frame(width: 130)
                divider
                network(s).padding(.horizontal, 10).frame(width: 198)
                divider
                statusPanel(s).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            // Dark halo keeps the green readable over any wallpaper.
            .compositingGroup()
            .shadow(color: .black.opacity(0.85), radius: 1.5)
        }
        .frame(width: DesktopWidgetController.size.width, height: DesktopWidgetController.size.height)
        .foregroundStyle(MatrixTheme.green)
        .contextMenu {
            Button("Ocultar widget") { monitor.showWidget = false }
        }
    }

    private var divider: some View {
        Rectangle().fill(MatrixTheme.green.opacity(0.19)).frame(width: 1).padding(.vertical, 4)
    }

    // MARK: Gauges

    private func gauges(_ s: SystemSnapshot) -> some View {
        let memPct = monitor.memoryPercent
        let fanPercents = s.fans.prefix(2).map { "\(Int(($0.fraction * 100).rounded()))%" }.joined(separator: "·")
        return HStack(spacing: 0) {
            gaugeColumn(title: "fans", detail: s.fans.isEmpty ? "—" : fanPercents,
                        help: s.fans.isEmpty ? "Sem ventoinha legível"
                            : zip(["L", "R"], s.fans).map { "\($0): \(Int($1.rpm)) rpm" }.joined(separator: " · ")) {
                FanSplitRing(fans: s.fans)
            }
            gaugeColumn(title: "temp", detail: s.temperatures.gpu.map { "gpu \(Int($0.rounded()))°" } ?? "—",
                        help: temperatureHelp(s.temperatures)) {
                MatrixHeatRing(celsius: s.temperatures.cpu, lineWidth: 5, radius: 21)
                    .overlay(Text(s.temperatures.cpu.map { "\(Int($0.rounded()))°" } ?? "—")
                        .font(MatrixTheme.font(13)).foregroundStyle(MatrixTheme.bright))
            }
            gaugeColumn(title: "cpu", detail: "\(s.cores.count) núc") {
                percentRing(s.cpuTotal, level: .cpu(s.cpuTotal))
            }
            gaugeColumn(title: "gpu", detail: s.gpuCores.map { "\($0) núc" } ?? "—") {
                percentRing(s.gpu ?? 0, level: .cpu(s.gpu ?? 0))
            }
            gaugeColumn(title: "mem", detail: "\(gb(s.memUsed))/\(gb(s.memTotal)) GB") {
                percentRing(memPct, level: monitor.memoryLevel)
            }
        }
    }

    private func percentRing(_ value: Double, level: Level) -> some View {
        MatrixRing(fraction: value / 100, lineWidth: 5, color: MatrixTheme.color(level), radius: 21)
            .overlay(Text("\(Int(value.rounded()))%").font(MatrixTheme.font(13)).foregroundStyle(MatrixTheme.bright))
    }

    private func temperatureHelp(_ t: SMC.Temperatures) -> String {
        let parts: [(String, Double?)] = [("CPU", t.cpu), ("GPU", t.gpu), ("SSD", t.ssd), ("bateria", t.battery)]
        return parts.compactMap { name, v in v.map { "\(name) \(Int($0.rounded())) °C" } }.joined(separator: " · ")
    }

    private func gb(_ bytes: UInt64) -> String {
        let v = Double(bytes) / 1_073_741_824
        return v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private func gaugeColumn<G: View>(title: String, detail: String, help: String? = nil,
                                      @ViewBuilder gauge: () -> G) -> some View {
        VStack(spacing: 3) {
            gauge().frame(width: 50, height: 50)
            Text(title).font(MatrixTheme.font(11))
            Text(detail).font(MatrixTheme.font(10)).foregroundStyle(MatrixTheme.dim).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .help(help ?? "")
    }

    // MARK: Cores

    private func cores(_ s: SystemSnapshot) -> some View {
        let e = min(s.efficiencyCores, s.cores.count)
        let perf = Array(s.cores.dropFirst(e))
        let eff = Array(s.cores.prefix(e))
        return VStack(alignment: .leading, spacing: 4) {
            CoresCanvas(performance: perf, efficiency: eff).frame(height: 60)
            HStack {
                Text("p-core[\(perf.count)]")
                Spacer()
                Text("e[\(eff.count)]")
            }
            .font(MatrixTheme.font(10)).foregroundStyle(MatrixTheme.dim)
            HStack {
                Text("disk>")
                Spacer()
                Text("r \(Fmt.short(s.diskReadRate))")
                Spacer()
                Text("w \(Fmt.short(s.diskWriteRate))")
            }
            .font(MatrixTheme.font(10))
            .lineLimit(1)
        }
    }

    // MARK: Network

    private func network(_ s: SystemSnapshot) -> some View {
        let downMbps = s.netInRate * 8 / 1_000_000
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("net>")
                Spacer()
                Text("↓\(Fmt.short(s.netInRate))")
                Text("↑\(Fmt.short(s.netOutRate))").foregroundStyle(MatrixTheme.bright)
            }
            .font(MatrixTheme.font(11))
            HStack(alignment: .center, spacing: 6) {
                Speedometer(mbps: downMbps).frame(width: 92, height: 76)
                    .help("Download agora em Mbps (escala 0 · 1 · 5 · 10 · 20 · 50 · 100+): \(Fmt.rate(s.netInRate))")
                lastSpeedTest
            }
        }
    }

    /// Last measured link capacity, named like the usual speed tests.
    private var lastSpeedTest: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let t = monitor.speed {
                let value = monitor.speedIsStale ? MatrixTheme.dim : MatrixTheme.bright
                Text("↓\(Self.mbps(t.downMbps))").font(MatrixTheme.font(17, .semibold)).foregroundStyle(value)
                Text("↑\(Self.mbps(t.upMbps))").font(MatrixTheme.font(17, .semibold)).foregroundStyle(value)
                    .padding(.top, 4)
            } else {
                Text(monitor.speedTesting ? "testando…" : "sem teste").font(MatrixTheme.font(12)).foregroundStyle(MatrixTheme.bright)
                Text("testa ao ficar ocioso").font(MatrixTheme.font(9)).foregroundStyle(MatrixTheme.dim)
            }
            Text(testFooter).font(MatrixTheme.font(8))
                .foregroundStyle(monitor.speed != nil && monitor.speedIsStale ? MatrixTheme.warn : MatrixTheme.dim).lineLimit(1)
                .padding(.top, 2)
        }
        .help(monitor.speed.map { "↓ transferência · ↑ carregamento, em Mbps — medido \(Fmt.ago($0.date)) com o teste da Apple" } ?? "Rode o teste de velocidade no painel")
    }

    private var testFooter: String {
        var parts: [String] = []
        if monitor.speedTesting { parts.append("testando…") }
        else if let t = monitor.speed { parts.append(Fmt.ago(t.date)) }
        if let w = monitor.wifi { parts.append("\(w.rssi)dBm") }
        return parts.joined(separator: " · ")
    }

    private static func mbps(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "pt_BR")))
    }

    // MARK: Battery, uptime, top network app, kill

    private func statusPanel(_ s: SystemSnapshot) -> some View {
        let topNet = monitor.top(by: .network, limit: 1).first
        return VStack(alignment: .leading, spacing: 4) {
            Text("up \(Fmt.duration(s.uptime))").font(MatrixTheme.font(11))
            if let g = topNet {
                let r = monitor.netRate(for: g)
                HStack(spacing: 4) {
                    Text(g.name.lowercased()).lineLimit(1).truncationMode(.tail)
                    Text(Fmt.short(r.down + r.up)).layoutPriority(1)
                }
                .font(MatrixTheme.font(10))
                .foregroundStyle(r.down + r.up >= Monitor.netHeavyRate ? MatrixTheme.warn : MatrixTheme.green)
                .help("Mais rede agora — \(g.name): ↓ \(Fmt.rate(r.down)) · ↑ \(Fmt.rate(r.up))")
            }
            if let top = monitor.suggestions.first {
                Text("> encerrar_").font(MatrixTheme.font(10)).padding(.top, 2)
                Text(top.name.lowercased()).font(MatrixTheme.font(10))
                    .foregroundStyle(MatrixTheme.color(top.level)).lineLimit(1)
                    .help(([Fmt.bytes(top.memory)] + top.reasons).joined(separator: " · "))
                Button {
                    if confirmKill { monitor.close(top); confirmKill = false } else { confirmKill = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(confirmKill ? "> ok? [y]" : "> kill")
                        Rectangle().fill(MatrixTheme.green).frame(width: 6, height: 11)
                    }
                    .font(MatrixTheme.font(10))
                    .foregroundStyle(confirmKill ? MatrixTheme.critical : MatrixTheme.green)
                }
                .buttonStyle(.plain)
                .help("Clique duas vezes para encerrar \(top.name) (fecha normalmente; avisa se houver algo não salvo)")
            } else {
                Text("> sistema ok_").font(MatrixTheme.font(10)).padding(.top, 2)
            }
            Button { monitor.runSpeedTest() } label: {
                Text(monitor.speedTesting ? "> testando…" : "> speed ⟳")
                    .font(MatrixTheme.font(10))
                    .foregroundStyle(monitor.speedTesting ? MatrixTheme.warn : MatrixTheme.green)
            }
            .buttonStyle(.plain)
            .disabled(monitor.speedTesting)
            .help("Medir a velocidade da internet agora (~30 s, usa algumas centenas de MB)")
        }
        // Centered on the same axis as the other columns instead of pinned to the edges.
        .lineLimit(1)
        .frame(maxHeight: .infinity, alignment: .center)
        .onChange(of: monitor.suggestions.first?.id) { _ in confirmKill = false }
    }
}

// MARK: - Pieces

struct MatrixRing: View {
    let fraction: Double
    let lineWidth: CGFloat
    let color: Color
    let radius: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(MatrixTheme.green.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

/// Temperature ring in one color, the current cold-to-hot band, like the menu bar gauge.
struct MatrixHeatRing: View {
    let celsius: Double?
    let lineWidth: CGFloat
    let radius: CGFloat

    private static let colors = [MatrixTheme.cold, MatrixTheme.green, MatrixTheme.warn, MatrixTheme.critical]

    var body: some View {
        MatrixRing(fraction: celsius.map(Heat.fraction) ?? 0, lineWidth: lineWidth,
                   color: celsius.map { t in Self.colors[Heat.bands.firstIndex { t < $0.upTo } ?? Self.colors.count - 1] } ?? .clear,
                   radius: radius)
    }
}

/// One ring split in two halves: left half = fan L, right half = fan R, both filling from the bottom up.
struct FanSplitRing: View {
    let fans: [SMC.Fan]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 3.5
            let span = 160.0                                    // degrees per half, leaves gaps top and bottom
            func arc(from start: Double, sweep: Double) -> Path {
                var path = Path()
                let steps = max(2, Int(abs(sweep) / 4))
                for k in 0...steps {
                    let a = (start + sweep * Double(k) / Double(steps)) * .pi / 180
                    let p = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
                    k == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                return path
            }
            let style = StrokeStyle(lineWidth: 5, lineCap: .butt)
            // Canvas angles: 90° is the bottom. Left half sweeps bottom -> left -> top (increasing angle).
            let leftStart = 90.0 + (180 - span) / 2
            let rightStart = 90.0 - (180 - span) / 2
            context.stroke(arc(from: leftStart, sweep: span), with: .color(MatrixTheme.green.opacity(0.15)), style: style)
            context.stroke(arc(from: rightStart, sweep: -span), with: .color(MatrixTheme.green.opacity(0.15)), style: style)
            if let l = fans.first, l.fraction > 0 {
                context.stroke(arc(from: leftStart, sweep: span * l.fraction),
                               with: .color(MatrixTheme.color(.fan(l.fraction))), style: style)
            }
            if fans.count > 1, fans[1].fraction > 0 {
                let r = fans[1]
                context.stroke(arc(from: rightStart, sweep: -span * r.fraction),
                               with: .color(MatrixTheme.color(.fan(r.fraction))), style: style)
            }
        }
        .overlay {
            HStack(spacing: 9) {
                Text("L")
                Text(fans.count > 1 ? "R" : " ")
            }
            .font(MatrixTheme.font(11))
            .foregroundStyle(MatrixTheme.bright)
        }
    }
}

/// Current download on a log scale (0...100+ Mbps), like a speed-test dial.
struct Speedometer: View {
    let mbps: Double
    /// Every tick is marked, only a few are labeled so the labels stay readable at this size.
    static let ticks: [(Double, String?)] = [(0, "0"), (1, nil), (5, nil), (10, "10"), (20, nil), (50, nil), (100, "100")]

    /// 0...1 position on the dial; log keeps idle traffic visible and 100 Mbps at the end.
    static func position(_ v: Double) -> Double { min(1, log10(1 + max(0, v)) / log10(101)) }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height * 0.62)
            let radius = min(size.width / 2 - 3, size.height * 0.62 - 3)
            let start = 150.0, sweep = 240.0          // Canvas angles: 90° = bottom, clockwise
            func point(_ t: Double, _ r: CGFloat) -> CGPoint {
                let a = (start + sweep * t) * .pi / 180
                return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            }
            func arc(to t: Double) -> Path {
                var path = Path()
                let steps = max(2, Int(sweep * t / 4))
                for k in 0...steps {
                    let p = point(t * Double(k) / Double(steps), radius)
                    k == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                return path
            }
            let style = StrokeStyle(lineWidth: 5, lineCap: .butt)
            context.stroke(arc(to: 1), with: .color(MatrixTheme.green.opacity(0.15)), style: style)
            let t = Self.position(mbps)
            if t > 0.005 { context.stroke(arc(to: t), with: .color(MatrixTheme.green), style: style) }

            for (value, label) in Self.ticks {
                let tt = Self.position(value)
                var tick = Path()
                tick.move(to: point(tt, radius - 3)); tick.addLine(to: point(tt, radius - 6))
                context.stroke(tick, with: .color(MatrixTheme.green.opacity(0.6)), lineWidth: 1.5)
                if let label {
                    context.draw(Text(label).font(MatrixTheme.font(10)).foregroundColor(MatrixTheme.green),
                                 at: point(tt, radius - 15))
                }
            }
            let value = mbps >= 10 ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps).replacingOccurrences(of: ".", with: ",")
            context.draw(Text(value).font(MatrixTheme.font(18, .semibold)).foregroundColor(MatrixTheme.bright),
                         at: CGPoint(x: center.x, y: center.y - 5))
            context.draw(Text("Mbps").font(MatrixTheme.font(10)).foregroundColor(MatrixTheme.green),
                         at: CGPoint(x: center.x, y: center.y + 13))
        }
    }
}

/// All cores as segmented bars in a single draw pass (cheaper than one view per segment).
struct CoresCanvas: View {
    let performance: [Double]
    let efficiency: [Double]
    private let segments = 10

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 3, groupGap: CGFloat = 9
            let count = CGFloat(performance.count + efficiency.count)
            guard count > 0 else { return }
            let width = (size.width - groupGap - gap * (count - 2)) / count
            let segH = (size.height - CGFloat(segments - 1) * 2) / CGFloat(segments)
            var x: CGFloat = 0
            for (i, load) in (performance + efficiency).enumerated() {
                if i == performance.count { x += groupGap - gap }
                let lit = max(1, Int((load / 100 * Double(segments)).rounded(.up)))
                let level = Level.cpu(load)
                let on = level == .ok ? MatrixTheme.green : MatrixTheme.color(level)
                for k in 0..<segments {
                    let y = size.height - CGFloat(k + 1) * segH - CGFloat(k) * 2
                    context.fill(Path(CGRect(x: x, y: y, width: width, height: segH)),
                                 with: .color(k < lit ? on : MatrixTheme.green.opacity(0.12)))
                }
                x += width + gap
            }
        }
    }
}
