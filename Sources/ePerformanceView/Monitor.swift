import AppKit
import Foundation
import ServiceManagement

/// A running app worth closing to free memory or relieve the disk, with why.
struct Suggestion: Identifiable {
    let id: String              // bundle path, same key as ProcessGroup.id
    let name: String
    let memory: UInt64
    var reasons: [String]
    var level: Level
    let app: NSRunningApplication
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var suggestions: [Suggestion] = []
    @Published var purgeMessage: String?
    @Published var purging = false

    @Published var idleMinutes: Int = UserDefaults.standard.object(forKey: "idleMinutes") as? Int ?? 15 {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: "idleMinutes"); refreshSuggestions() }
    }
    /// Only apps using at least this much memory are suggested for closing.
    @Published var idleMinMemoryMB: Int = UserDefaults.standard.object(forKey: "idleMinMemoryMB") as? Int ?? 300 {
        didSet { UserDefaults.standard.set(idleMinMemoryMB, forKey: "idleMinMemoryMB"); refreshSuggestions() }
    }

    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginMessage: String?

    @Published var showWidget: Bool = UserDefaults.standard.object(forKey: "showWidget") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showWidget, forKey: "showWidget")
            showWidget ? widget.show(monitor: self) : widget.hide()
        }
    }
    private let widget = DesktopWidgetController()

    /// Bundle paths the user allowed to stay open; they are never suggested for closing.
    @Published private(set) var keptOpen: [String] = UserDefaults.standard.stringArray(forKey: "keptOpen") ?? []

    func isKeptOpen(_ path: String) -> Bool { keptOpen.contains(path) }

    func setKeptOpen(_ path: String, _ keep: Bool) {
        keptOpen.removeAll { $0 == path }
        if keep { keptOpen.append(path); keptOpen.sort { Self.appName($0) < Self.appName($1) } }
        UserDefaults.standard.set(keptOpen, forKey: "keptOpen")
        refreshSuggestions()
    }

    /// Running user apps that could be added to the kept-open list.
    var addableApps: [String] {
        let paths = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { $0.bundleURL?.path }
        return Array(Set(paths)).filter { !keptOpen.contains($0) }.sorted { Self.appName($0) < Self.appName($1) }
    }

    static func appName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: Network
    @Published private(set) var netByPid: [pid_t: (down: Double, up: Double)] = [:]
    @Published private(set) var pingMs: Double?
    @Published private(set) var todayDown: UInt64 = UInt64(UserDefaults.standard.double(forKey: "todayDown"))
    @Published private(set) var todayUp: UInt64 = UInt64(UserDefaults.standard.double(forKey: "todayUp"))
    private var todayKey: String = UserDefaults.standard.string(forKey: "todayKey") ?? ""
    private var lastNetTotals: (down: UInt64, up: UInt64)?
    private let netActivity = NetActivity()
    @Published private(set) var wifi: WiFiInfo?

    // MARK: Link speed test
    @Published private(set) var speed: SpeedResult? = {
        guard let data = UserDefaults.standard.data(forKey: "speedResult") else { return nil }
        return try? JSONDecoder().decode(SpeedResult.self, from: data)
    }()
    @Published private(set) var speedTesting = false
    /// Minimum hours between automatic tests, which only run while the Mac is idle; 0 = only when the user asks.
    /// The gap matters: a Mac left idle overnight would otherwise test again every few minutes.
    @Published var speedTestGapHours: Int = UserDefaults.standard.object(forKey: "speedTestGapHours") as? Int ?? 4 {
        didSet { UserDefaults.standard.set(speedTestGapHours, forKey: "speedTestGapHours") }
    }
    /// Nobody touched the keyboard or mouse for this long, so a ~20 s saturated link bothers no one.
    static let speedTestIdle: TimeInterval = 10 * 60
    /// After this the shown result is flagged as old.
    static let speedStaleAfter: TimeInterval = 12 * 3600
    var speedIsStale: Bool { speed.map { Date().timeIntervalSince($0.date) > Self.speedStaleAfter } ?? true }
    /// Automatic tests wait while the link is busy, so they don't disturb real work.
    static let speedTestBusyRate = 2.0 * 1_048_576

    func runSpeedTest() {
        guard !speedTesting else { return }
        speedTesting = true
        DispatchQueue.global(qos: .utility).async {
            let result = SpeedTest.run()
            DispatchQueue.main.async {
                self.speedTesting = false
                guard let result else { return }
                self.speed = result
                if let data = try? JSONEncoder().encode(result) { UserDefaults.standard.set(data, forKey: "speedResult") }
            }
        }
    }

    /// Tests automatically only when the user is away, on AC power, with a quiet link, and the last result is old enough.
    private func maybeRunSpeedTest(_ s: SystemSnapshot) {
        guard speedTestGapHours > 0, !speedTesting,
              s.battery?.onAC ?? true,
              s.netInRate + s.netOutRate < Self.speedTestBusyRate,
              Self.userIdleSeconds() >= Self.speedTestIdle else { return }
        if let last = speed?.date, s.date.timeIntervalSince(last) < Double(speedTestGapHours) * 3600 { return }
        runSpeedTest()
    }

    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    static func userIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Current download as a share of the measured link capacity.
    var linkUsePercent: Double? {
        guard let speed, speed.downMbps > 0 else { return nil }
        return min(100, snapshot.netInRate * 8 / 1_000_000 / speed.downMbps * 100)
    }
    /// An app above this combined throughput is highlighted.
    static let netHeavyRate = 5.0 * 1_048_576

    func netRate(for g: ProcessGroup) -> (down: Double, up: Double) {
        g.pids.reduce((0, 0)) { acc, pid in
            let r = netByPid[pid] ?? (0, 0)
            return (acc.0 + r.down, acc.1 + r.up)
        }
    }

    private func recordNetwork(_ s: SystemSnapshot) {
        let key = Self.dayFormatter.string(from: s.date)
        if key != todayKey { todayKey = key; todayDown = 0; todayUp = 0 }
        if let last = lastNetTotals, s.netInTotal >= last.down, s.netOutTotal >= last.up {
            todayDown += s.netInTotal - last.down
            todayUp += s.netOutTotal - last.up
        }
        lastNetTotals = (s.netInTotal, s.netOutTotal)
        let d = UserDefaults.standard
        d.set(Double(todayDown), forKey: "todayDown"); d.set(Double(todayUp), forKey: "todayUp"); d.set(todayKey, forKey: "todayKey")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    let updater = Updater()
    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "eperformanceview.sampler", qos: .utility)
    private var timer: Timer?
    private var busy = false
    /// Smoothed disk throughput per group (~30 s memory) so a short burst is not flagged.
    private var diskAverage: [String: Double] = [:]

    /// Sustained disk throughput that gets an app flagged.
    static let diskWarnRate = 5.0 * 1_048_576
    static let diskCriticalRate = 20.0 * 1_048_576

    init() {
        // Opt in once on first launch; afterwards the user's choice in the panel wins.
        let d = UserDefaults.standard
        if !d.bool(forKey: "loginItemConfigured") {
            d.set(true, forKey: "loginItemConfigured")
            setLaunchAtLogin(true)
        } else if d.object(forKey: "launchAtLoginWanted") as? Bool ?? true, SMAppService.mainApp.status != .enabled {
            // A renamed or updated bundle is a new login item; re-register what the user chose.
            setLaunchAtLogin(true)
        }
        updater.startChecking()
        tick()
        netActivity.start { [weak self] update in
            DispatchQueue.main.async {
                self?.netByPid = update.ratesByPid
                self?.pingMs = update.pingMs
                self?.wifi = update.wifi
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 1
        if showWidget {
            DispatchQueue.main.async { self.widget.show(monitor: self) }
        }
    }

    private func tick() {
        guard !busy else { return }
        busy = true
        queue.async { [sampler] in
            let s = sampler.sample()
            DispatchQueue.main.async {
                self.snapshot = s
                self.recordNetwork(s)
                self.maybeRunSpeedTest(s)
                self.busy = false
                self.refreshSuggestions()
            }
        }
    }

    func top(by metric: Metric, limit: Int = 8) -> [ProcessGroup] {
        let sorted: [ProcessGroup]
        switch metric {
        case .cpu: sorted = snapshot.groups.sorted { $0.cpu > $1.cpu }
        case .memory: sorted = snapshot.groups.sorted { $0.memory > $1.memory }
        case .disk: sorted = snapshot.groups.sorted { ($0.diskRead + $0.diskWrite) > ($1.diskRead + $1.diskWrite) }
        case .network:
            let total = { (g: ProcessGroup) -> Double in let r = self.netRate(for: g); return r.down + r.up }
            sorted = snapshot.groups.filter { total($0) > 0 }.sorted { total($0) > total($1) }
        }
        return Array(sorted.prefix(limit))
    }

    var memoryPercent: Double { Double(snapshot.memUsed) / Double(max(1, snapshot.memTotal)) * 100 }
    var memoryLevel: Level { .memory(percent: memoryPercent, pressure: snapshot.pressure) }
    var worstSuggestion: Level? { suggestions.map(\.level).max() }

    private func refreshSuggestions() {
        let now = snapshot.date
        for g in snapshot.groups {
            diskAverage[g.id] = 0.25 * (g.diskRead + g.diskWrite) + 0.75 * (diskAverage[g.id] ?? 0)
        }
        let live = Set(snapshot.groups.map(\.id))
        diskAverage = diskAverage.filter { live.contains($0.key) }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let groupsByBundle = Dictionary(snapshot.groups.compactMap { g in g.bundlePath.map { ($0, g) } }, uniquingKeysWith: { a, _ in a })
        let memLevel = memoryLevel
        // Under memory pressure the biggest apps are named even if busy; otherwise only idle ones.
        let heavyLimit = UInt64(1) << 30
        let heavyIDs = Set(snapshot.groups.filter { $0.bundlePath != nil && $0.memory >= heavyLimit }
            .sorted { $0.memory > $1.memory }.prefix(3).map(\.id))

        var result: [Suggestion] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != front, app.processIdentifier != getpid(),
                  app.bundleIdentifier != "com.apple.finder",
                  let path = app.bundleURL?.path, !keptOpen.contains(path),
                  let g = groupsByBundle[path] else { continue }
            var reasons: [String] = []
            var level: Level = .ok

            if let since = g.idleSince {
                let idle = now.timeIntervalSince(since)
                if idle >= Double(idleMinutes * 60), g.memory >= UInt64(idleMinMemoryMB) * 1_048_576 {
                    reasons.append("parado há \(Fmt.duration(idle))")
                    level = max(level, .warn)
                }
            }
            if memLevel != .ok, heavyIDs.contains(g.id) {
                reasons.append("libera \(Fmt.bytes(g.memory)) de memória")
                level = max(level, memLevel)
            }
            let disk = diskAverage[g.id] ?? 0
            if disk >= Self.diskWarnRate {
                reasons.append("disco contínuo \(Fmt.rate(disk))")
                level = max(level, disk >= Self.diskCriticalRate ? .critical : .warn)
            }
            guard !reasons.isEmpty else { continue }
            result.append(Suggestion(id: path, name: g.name, memory: g.memory, reasons: reasons, level: level, app: app))
        }
        suggestions = result.sorted { ($0.level, $0.memory) > ($1.level, $1.memory) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "launchAtLoginWanted")
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = nil
        } catch {
            loginMessage = "Não foi possível alterar: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Asks the app to quit normally; it still prompts to save unsaved documents.
    func close(_ suggestion: Suggestion) {
        suggestion.app.terminate()
        suggestions.removeAll { $0.id == suggestion.id }
    }

    /// Runs `purge` (drops the file cache) with the macOS administrator prompt.
    func purge() {
        purging = true
        purgeMessage = nil
        let before = snapshot.memUsed
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"/usr/sbin/purge\" with administrator privileges")
            script?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                self.purging = false
                if let error, (error[NSAppleScript.errorNumber] as? Int) == -128 {
                    self.purgeMessage = "Cancelado."
                } else if error != nil {
                    self.purgeMessage = "Falhou: \(error?[NSAppleScript.errorMessage] ?? "erro desconhecido")"
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                        let freed = Int64(before) - Int64(self.snapshot.memUsed)
                        self.purgeMessage = freed > 0 ? "Liberado ≈ \(Fmt.bytes(UInt64(freed)))" : "Cache limpo."
                    }
                }
            }
        }
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memória", disk = "Disco", network = "Rede"
    var id: String { rawValue }
}

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
    static func rate(_ r: Double) -> String {
        r < 1024 ? "0 KB/s" : ByteCountFormatter.string(fromByteCount: Int64(r), countStyle: .file) + "/s"
    }
    /// Compact rate for tight layouts: "420K", "9,8M".
    static func short(_ r: Double) -> String {
        if r < 1024 { return "0K" }
        if r < 1_048_576 { return "\(Int(r / 1024))K" }
        let m = r / 1_048_576
        return m < 10 ? String(format: "%.1fM", m).replacingOccurrences(of: ".", with: ",") : "\(Int(m))M"
    }

    static func ago(_ date: Date) -> String {
        let t = Date().timeIntervalSince(date)
        return t < 60 ? "agora" : "há \(duration(t))"
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m >= 1440 { return "\(m / 1440)d \(m % 1440 / 60)h" }
        return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))" : "\(m) min"
    }
}
