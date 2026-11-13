import AppKit
import SwiftUI

@main
struct EPerformanceViewApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        Image(nsImage: MenuBarImage.make(gauges: monitor.gauges, net: monitor.menuBarNet,
                                         alertCount: monitor.suggestions.count,
                                         alertLevel: monitor.worstSuggestion))
    }
}

struct PanelView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var metric: Metric = .cpu
    @State private var showSettings = false
    @State private var expanded: String?

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 10) {
            summary(s)
            Divider()
            Picker("", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            processList
            if metric == .disk {
                Text("Disco por processo só aparece para processos do seu usuário; o total acima inclui o sistema.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if metric == .network {
                Text("Por app atualiza a cada ~6 s e inclui processos do sistema.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            idleSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Summary

    private func summary(_ s: SystemSnapshot) -> some View {
        let memFrac = Double(s.memUsed) / Double(max(1, s.memTotal))
        return VStack(alignment: .leading, spacing: 8) {
            StatRow(icon: "cpu", title: "CPU", value: "\(Int(s.cpuTotal))%", fraction: s.cpuTotal / 100,
                    detail: thermalText(s.thermal), tint: Level.cpu(s.cpuTotal).color)
            StatRow(icon: "memorychip", title: "Memória",
                    value: "\(Fmt.bytes(s.memUsed)) de \(Fmt.bytes(s.memTotal))", fraction: memFrac,
                    detail: pressureText(s.pressure) + (s.swapUsed > 0 ? " · swap \(Fmt.bytes(s.swapUsed))" : ""),
                    tint: Level.memory(percent: memFrac * 100, pressure: s.pressure).color)
            HStack {
                Label("Disco", systemImage: "internaldrive").frame(width: 92, alignment: .leading)
                Text("↓ \(Fmt.rate(s.diskReadRate))  ↑ \(Fmt.rate(s.diskWriteRate))").monospacedDigit()
                Spacer()
                Text("livre \(Fmt.bytes(UInt64(max(0, s.diskFree))))").foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack {
                Label("Rede", systemImage: "network").frame(width: 92, alignment: .leading)
                Text("↓ \(Fmt.rate(s.netInRate))  ↑ \(Fmt.rate(s.netOutRate))").monospacedDigit()
                Spacer()
                Text(monitor.pingMs.map { "ping \(Int($0.rounded())) ms" } ?? "ping —").foregroundStyle(.secondary)
            }
            .font(.callout)
            Text("Hoje: ↓ \(Fmt.bytes(monitor.todayDown)) · ↑ \(Fmt.bytes(monitor.todayUp))")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 92)
            LinkSection()
            if let gpu = s.gpu {
                StatRow(icon: "cpu.fill", title: "GPU", value: "\(Int(gpu.rounded()))%", fraction: gpu / 100,
                        detail: s.gpuCores.map { "\($0) núcleos" } ?? "", tint: Level.cpu(gpu).color)
            }
            fanRow(s)
        }
    }

    @ViewBuilder private func fanRow(_ s: SystemSnapshot) -> some View {
        if s.fans.isEmpty {
            HStack {
                Label("Ventoinha", systemImage: "fan").frame(width: 92, alignment: .leading)
                Text("sem ventoinha / não acessível").foregroundStyle(.secondary)
            }.font(.callout)
        } else {
            let hottest = s.groups.max { $0.cpu < $1.cpu }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Ventoinha", systemImage: s.fans.contains { $0.rpm > 0 } ? "fan.fill" : "fan")
                        .frame(width: 92, alignment: .leading)
                    Text(s.fans.map { $0.rpm > 0 ? "\(Int($0.rpm)) rpm" : "parada" }.joined(separator: " · "))
                        .monospacedDigit()
                }
                if s.fans.contains(where: { $0.rpm > 0 }) || s.thermal.rawValue >= 1, let h = hottest {
                    Text("Quem está aquecendo: \(h.name) (\(Int(h.cpu))% CPU)")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.font(.callout)
        }
    }

    private func thermalText(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "temperatura normal"
        case .fair: return "aquecendo"
        case .serious: return "quente — desempenho reduzido"
        case .critical: return "crítico"
        @unknown default: return ""
        }
    }

    private func pressureText(_ p: Int) -> String {
        p >= 4 ? "pressão crítica" : p >= 2 ? "pressão alta" : "pressão normal"
    }

    // MARK: List

    private var processList: some View {
        VStack(spacing: 2) {
            ForEach(monitor.top(by: metric)) { g in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: expanded == g.id ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 8)
                        AppIcon(path: g.iconPath)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(g.name).lineLimit(1).truncationMode(.middle)
                            Text(subtitle(for: g)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let path = g.bundlePath, monitor.isKeptOpen(path) {
                            Image(systemName: "pin.fill").foregroundStyle(.secondary).help("Liberado para ficar aberto")
                        } else if let flag = monitor.suggestions.first(where: { $0.id == g.id }) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(flag.level.color)
                                .help("Sugerido encerrar: " + flag.reasons.joined(separator: ", "))
                        }
                        Text(value(for: g)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { expanded = expanded == g.id ? nil : g.id }
                    if expanded == g.id { details(for: g) }
                }
                .font(.callout)
                .padding(.vertical, 2)
            }
        }
    }

    private func subtitle(for g: ProcessGroup) -> String {
        var parts: [String] = []
        if g.processes.count > 1 { parts.append("\(g.processes.count) processos") }
        if let owner = g.ownerName { parts.append("aberto por \(owner)") }
        parts.append("há \(Fmt.duration(g.elapsed))")
        return parts.joined(separator: " · ")
    }

    /// Every process in the group: pid, CPU, memory and how long it has been running.
    private func details(for g: ProcessGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(g.processes.sorted { $0.memory > $1.memory }.prefix(12)) { p in
                HStack(spacing: 6) {
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("pid \(p.id)").foregroundStyle(.tertiary)
                    Text(String(format: "%.0f%%", p.cpu)).frame(width: 36, alignment: .trailing)
                    Text(Fmt.bytes(p.memory)).frame(width: 64, alignment: .trailing)
                    Text(Fmt.duration(p.elapsed)).frame(width: 48, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if g.processes.count > 12 {
                Text("+ \(g.processes.count - 12) processos menores").font(.caption2).foregroundStyle(.tertiary)
            }
            if let owner = g.ownerName {
                Text("Para liberar: feche ou pare isso dentro de \(owner).").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 34)
        .padding(.vertical, 2)
    }

    private func value(for g: ProcessGroup) -> String {
        switch metric {
        case .cpu: return String(format: "%.1f%%", g.cpu)
        case .memory: return Fmt.bytes(g.memory)
        case .disk:
            guard g.diskKnown else { return "—" }
            return "↓\(Fmt.rate(g.diskRead)) ↑\(Fmt.rate(g.diskWrite))"
        case .network:
            let r = monitor.netRate(for: g)
            return "↓\(Fmt.rate(r.down)) ↑\(Fmt.rate(r.up))"
        }
    }

    // MARK: Suggestions

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Encerrar para liberar").font(.headline)
                Spacer()
                Button { showSettings.toggle() } label: {
                    Label("\(monitor.keptOpen.count) liberados", systemImage: "pin")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Apps liberados para ficar abertos e critérios de ociosidade")
            }
            if showSettings {
                Stepper("Ocioso: parado há ≥ \(monitor.idleMinutes) min", value: $monitor.idleMinutes, in: 1...240, step: 5)
                Stepper("Ocioso: usando ≥ \(monitor.idleMinMemoryMB) MB", value: $monitor.idleMinMemoryMB, in: 50...4000, step: 50)
                KeptOpenEditor()
            }
            SuggestionList(compact: false)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    monitor.purge()
                } label: {
                    Label(monitor.purging ? "Liberando…" : "Limpar cache de memória", systemImage: "arrow.3.trianglepath")
                }
                .disabled(monitor.purging)
                .help("Executa o purge do macOS (pede senha de administrador)")
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: { Image(systemName: "chart.bar.xaxis") }
                    .help("Abrir Monitor de Atividade")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Sair do ePerformance View")
            }
            if let msg = monitor.purgeMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Mostrar widget na área de trabalho", isOn: $monitor.showWidget)
                .toggleStyle(.checkbox)
                .font(.callout)
            Toggle("Abrir ao iniciar o Mac", isOn: Binding(
                get: { monitor.launchAtLogin },
                set: { monitor.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.callout)
            if let msg = monitor.loginMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
            }
            UpdateRow(updater: monitor.updater)
        }
    }
}

/// Current version and the GitHub update check, at the bottom of the panel.
struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            Text("Versão \(updater.currentVersion)").foregroundStyle(.secondary)
            Spacer()
            switch updater.state {
            case .idle, .upToDate, .failed:
                if case .upToDate = updater.state { Text("atualizado").foregroundStyle(.secondary) }
                Button("Verificar atualização") { updater.check() }.controlSize(.small)
            case .checking:
                ProgressView().controlSize(.small)
                Text("verificando…").foregroundStyle(.secondary)
            case .available(let r):
                Button("Atualizar para \(r.version)") { updater.install(r) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .help("Baixa do GitHub, troca o app e reabre")
                Link(destination: r.pageURL) { Image(systemName: "doc.text") }.help("O que mudou")
            case .installing(let r):
                ProgressView().controlSize(.small)
                Text("instalando \(r.version)…").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        if case .failed(let msg) = updater.state {
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }
}

struct StatRow: View {
    let icon: String
    let title: String
    let value: String
    let fraction: Double
    var detail: String = ""
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(title, systemImage: icon).frame(width: 92, alignment: .leading)
                Text(value).monospacedDigit()
                Spacer()
                Text(detail).foregroundStyle(.secondary).font(.caption)
            }
            ProgressView(value: min(1, max(0, fraction))).tint(tint)
        }
        .font(.callout)
    }
}

struct AppIcon: View {
    let path: String?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
    }

    private var icon: NSImage {
        let key = path ?? "/bin/sh"
        if let cached = Self.cache[key] { return cached }
        let img = path.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        Self.cache[key] = img
        return img
    }
}

/// Apps worth closing, each with its reason and a two-step close button.
struct SuggestionList: View {
    @EnvironmentObject var monitor: Monitor
    let compact: Bool
    @State private var confirmClose: String?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if monitor.suggestions.isEmpty {
                Label("Nada precisa ser encerrado agora.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Level.ok.color)
            } else {
                ForEach(monitor.suggestions.prefix(compact ? 3 : 8)) { item in
                    HStack(spacing: 6) {
                        Circle().fill(item.level.color).frame(width: 7, height: 7)
                        AppIcon(path: item.id).frame(width: compact ? 14 : 18, height: compact ? 14 : 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name).lineLimit(1)
                            Text(([Fmt.bytes(item.memory)] + item.reasons).joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                        }
                        Spacer(minLength: 4)
                        Button { monitor.setKeptOpen(item.id, true) } label: { Image(systemName: "pin") }
                            .buttonStyle(.borderless)
                            .help("Liberar para ficar aberto (não sugerir mais)")
                        if confirmClose == item.id {
                            Button("Confirmar") { monitor.close(item); confirmClose = nil }
                                .tint(.red).buttonStyle(.borderedProminent).controlSize(.small)
                        } else {
                            Button("Encerrar") { confirmClose = item.id }.controlSize(.small)
                        }
                    }
                    .font(compact ? .caption : .callout)
                }
                if !compact {
                    Text("Encerrar pede ao app para fechar normalmente; ele avisa se houver algo não salvo.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Add or remove apps from the "allowed to stay open" list.
struct KeptOpenEditor: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Liberados para ficar abertos", systemImage: "pin.fill").font(.callout.weight(.medium))
                Spacer()
                Menu("Adicionar") {
                    ForEach(monitor.addableApps, id: \.self) { path in
                        Button(Monitor.appName(path)) { monitor.setKeptOpen(path, true) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if monitor.keptOpen.isEmpty {
                Text("Nenhum. Use o alfinete numa sugestão ou \"Adicionar\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.keptOpen, id: \.self) { path in
                HStack(spacing: 6) {
                    AppIcon(path: path).frame(width: 16, height: 16)
                    Text(Monitor.appName(path)).lineLimit(1)
                    Spacer()
                    Button { monitor.setKeptOpen(path, false) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Retirar: voltar a sugerir quando estiver ocioso ou pesado")
                }
                .font(.callout)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Wi-Fi radio info (always on, free) and the speed test (manual by default, uses data).
struct LinkSection: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Link", systemImage: "globe").frame(width: 92, alignment: .leading)
                if let sp = monitor.speed {
                    Text("↓ \(Int(sp.downMbps.rounded())) · ↑ \(Int(sp.upMbps.rounded())) Mbps").monospacedDigit()
                    Spacer()
                    Text(Fmt.ago(sp.date)).foregroundStyle(monitor.speedIsStale ? Level.warn.color : .secondary)
                } else {
                    Text("ainda não medido").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .font(.callout)
            Group {
                if let w = monitor.wifi {
                    Text([w.generation, w.band, w.channel.map { "canal \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    Text("Sinal \(w.rssi) dBm (\(w.signalLabel)) · ruído \(w.noise) dBm · rádio \(Int(w.txRateMbps)) Mbps")
                        .foregroundStyle(w.signalLevel == .ok ? Color.secondary : w.signalLevel.color)
                } else {
                    Text("Sem Wi-Fi ativo (cabo ou desconectado).")
                }
                if let use = monitor.linkUsePercent {
                    Text("Uso agora: \(Int(use.rounded()))% do link")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.leading, 92)
            HStack(spacing: 8) {
                Button(monitor.speedTesting ? "Testando…" : "Testar velocidade") { monitor.runSpeedTest() }
                    .controlSize(.small).disabled(monitor.speedTesting)
                Picker("", selection: $monitor.speedTestGapHours) {
                    Text("Só manual").tag(0)
                    Text("Ocioso · 2 h").tag(2)
                    Text("Ocioso · 4 h").tag(4)
                    Text("Ocioso · 1×/dia").tag(24)
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .help("Testa sozinho, no máximo 1× a cada 2 h, 4 h ou por dia, depois de \(Int(Monitor.speedTestIdle / 60)) min sem teclado e mouse, na tomada e com a rede parada. Cada teste usa algumas centenas de MB.")
            }
            .padding(.leading, 92)
        }
    }
}
