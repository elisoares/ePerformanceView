import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// One process inside a group, for the expanded detail view.
struct ProcessDetail: Identifiable {
    let id: pid_t
    let name: String
    let cpu: Double
    let memory: UInt64
    let elapsed: TimeInterval   // how long it has been running
}

/// One application (or standalone process) with its helpers aggregated.
struct ProcessGroup: Identifiable {
    let id: String              // bundle path, or executable path plus owner
    let name: String
    let bundlePath: String?     // set only for real app bundles (closable apps)
    /// App that launched a generic system process (e.g. the app running a virtual machine).
    var ownerName: String? = nil
    var ownerPath: String? = nil
    var processes: [ProcessDetail] = []
    var pids: [pid_t] { processes.map(\.id) }
    var elapsed: TimeInterval { processes.map(\.elapsed).max() ?? 0 }
    var iconPath: String? { bundlePath ?? ownerPath }
    var cpu: Double = 0         // percent of one core, like Activity Monitor
    var memory: UInt64 = 0      // bytes (footprint when readable, RSS otherwise)
    var diskRead: Double = 0    // bytes/s
    var diskWrite: Double = 0   // bytes/s
    var diskKnown = false       // false when every process belongs to another user (root)
    var idleSince: Date?        // set when the group has been quiet since that date
}

struct Battery {
    let percent: Int
    let charging: Bool
    let onAC: Bool
}

struct SystemSnapshot {
    var cpuTotal: Double = 0            // 0...100 of the whole machine
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    var pressure: Int = 1               // 1 normal, 2 warning, 4 critical
    var diskReadRate: Double = 0
    var diskWriteRate: Double = 0
    var diskFree: Int64 = 0
    var fans: [SMC.Fan] = []
    var thermal: ProcessInfo.ThermalState = .nominal
    var groups: [ProcessGroup] = []
    /// Load of each logical core, 0...100, in macOS order (efficiency cores first on Apple silicon).
    var cores: [Double] = []
    var efficiencyCores: Int = Sampler.efficiencyCoreCount
    var gpu: Double?                    // 0...100, nil when unreadable
    var gpuCores: Int? = Sampler.gpuCoreCount
    var netInRate: Double = 0           // bytes/s over physical interfaces (en*)
    var netOutRate: Double = 0
    var netInTotal: UInt64 = 0          // interface counters, used for "today" totals
    var netOutTotal: UInt64 = 0
    var battery: Battery?
    var uptime: TimeInterval = 0
    var date = Date()
}

/// Collects samples on a background queue. Not thread-safe; only used from `queue`.
final class Sampler: @unchecked Sendable { // only touched from the serial sampler queue
    private let smc = SMC()
    private var prevCPUTicks: [UInt32]?
    private var prevCoreTicks: [[UInt32]] = []
    private var prevNet: (inB: UInt64, outB: UInt64, at: Date)?

    static let gpuCoreCount: Int? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }()

    static let efficiencyCoreCount: Int = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0 ? Int(n) : 0
    }()
    private var prevDiskTotals: (read: UInt64, write: UInt64, at: Date)?
    private var prevPidDisk: [pid_t: (read: UInt64, write: UInt64)] = [:]
    private var prevAt = Date()
    private var lastActive: [String: Date] = [:]
    private let ownPid = getpid()

    /// CPU percent below which a group counts as idle.
    static let idleCPUThreshold = 1.0

    func sample() -> SystemSnapshot {
        let now = Date()
        let interval = max(0.5, now.timeIntervalSince(prevAt))
        prevAt = now

        var s = SystemSnapshot()
        s.date = now
        s.cpuTotal = cpuTotal()
        s.cores = coreLoads()
        s.gpu = gpuUtilization()
        let net = netCounters()
        (s.netInTotal, s.netOutTotal) = net
        if let p = prevNet, net.0 >= p.inB, net.1 >= p.outB {
            let dt = max(0.5, now.timeIntervalSince(p.at))
            s.netInRate = Double(net.0 - p.inB) / dt
            s.netOutRate = Double(net.1 - p.outB) / dt
        }
        prevNet = (net.0, net.1, now)
        s.battery = battery()
        s.uptime = uptime()
        (s.memUsed, s.pressure, s.swapUsed) = memory()
        (s.diskReadRate, s.diskWriteRate) = diskRates(now: now)
        s.diskFree = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        s.fans = smc?.fans() ?? []
        s.thermal = ProcessInfo.processInfo.thermalState
        s.groups = groups(interval: interval, now: now)
        return s
    }

    // MARK: - System totals

    private func cpuTotal() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3] // user, system, idle, nice
        defer { prevCPUTicks = ticks }
        guard let prev = prevCPUTicks else { return 0 }
        let d = zip(ticks, prev).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (total - d[2]) / total * 100 : 0
    }

    private func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }

    /// 64-bit byte counters of the physical interfaces (en*); VPN tunnels would double count.
    private func netCounters() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(msg.ifm_index), &nameBuf) != nil,
                       String(cString: nameBuf).hasPrefix("en") {
                        inBytes += msg.ifm_data.ifi_ibytes
                        outBytes += msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (inBytes, outBytes)
    }

    private func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Battery(percent: current * 100 / maximum,
                           charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    private func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    private func coreLoads() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        let ticks: [[UInt32]] = (0..<Int(count)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
        defer { prevCoreTicks = ticks }
        guard prevCoreTicks.count == ticks.count else { return Array(repeating: 0, count: ticks.count) }
        return zip(ticks, prevCoreTicks).map { cur, prev in
            let d = zip(cur, prev).map { Double($0 &- $1) }
            let total = d.reduce(0, +)
            return total > 0 ? (total - d[Int(CPU_STATE_IDLE)]) / total * 100 : 0
        }
    }

    private func memory() -> (used: UInt64, pressure: Int, swap: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var used: UInt64 = 0
        if r == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // Same definition as Activity Monitor's "Memory Used": app + wired + compressed.
            let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
            used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return (used, Int(level), swap.xsu_used)
    }

    private func diskRates(now: Date) -> (Double, Double) {
        var read: UInt64 = 0, write: UInt64 = 0
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == kIOReturnSuccess else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        defer { prevDiskTotals = (read, write, now) }
        guard let p = prevDiskTotals, read >= p.read, write >= p.write else { return (0, 0) }
        let dt = max(0.5, now.timeIntervalSince(p.at))
        return (Double(read - p.read) / dt, Double(write - p.write) / dt)
    }

    // MARK: - Processes

    private struct PSRow { let pid: pid_t; let elapsed: TimeInterval; let cpu: Double; let rss: UInt64; let path: String }

    /// `ps` is setuid root on macOS, so it sees CPU and RSS of every process, including system ones.
    private func psRows() -> [PSRow] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,etime=,%cpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [PSRow] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = pid_t(parts[0]),
                  let cpu = Double(parts[2].replacingOccurrences(of: ",", with: ".")),
                  let rss = UInt64(parts[3]) else { continue }
            rows.append(PSRow(pid: pid, elapsed: Self.parseElapsed(parts[1]), cpu: cpu, rss: rss * 1024, path: String(parts[4])))
        }
        return rows
    }

    /// `ps` etime: [[dd-]hh:]mm:ss
    private static func parseElapsed(_ text: Substring) -> TimeInterval {
        let dayParts = text.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        let seconds = clock.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }

    /// Readable name for a bare executable: "com.apple.Virtualization.VirtualMachine" -> "Máquina virtual".
    private static func shortName(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        let dotted = name.split(separator: ".")
        if dotted.count >= 3 { name = String(dotted.last!) }
        let friendly = ["VirtualMachine": "Máquina virtual", "WebContent": "Conteúdo web",
                        "Networking": "Rede", "GPU": "GPU", "Rendering": "Renderização"]
        return friendly[name] ?? name
    }

    /// The app macOS holds responsible for a process (who launched an XPC service, VM, helper...).
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()
    private var ownerCache: [pid_t: String?] = [:]

    private func ownerPath(of pid: pid_t) -> String? {
        if let cached = ownerCache[pid] { return cached }
        var result: String?
        if let fn = Self.responsibleFn {
            let owner = fn(pid)
            if owner > 0, owner != pid {
                var buf = [CChar](repeating: 0, count: 4096)
                if proc_pidpath(owner, &buf, UInt32(buf.count)) > 0 { result = String(cString: buf) }
            }
        }
        ownerCache[pid] = result
        return result
    }

    /// Outermost `.app` bundle in the path groups helpers with their app.
    private static func identity(for path: String) -> (key: String, name: String, bundle: String?) {
        if let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) {
            let bundle = String(path[..<range.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let bundlePath = bundle.hasPrefix("/") ? bundle : "/" + bundle
            let name = (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return (bundlePath, name, bundlePath)
        }
        return (path, shortName(path), nil)
    }

    private func groups(interval: TimeInterval, now: Date) -> [ProcessGroup] {
        var byKey: [String: ProcessGroup] = [:]
        var seenDisk: [pid_t: (read: UInt64, write: UInt64)] = [:]

        let rows = psRows()
        let livePids = Set(rows.map(\.pid))
        ownerCache = ownerCache.filter { livePids.contains($0.key) }

        for row in rows where row.pid != ownPid && row.pid > 0 {
            var ident = Self.identity(for: row.path)
            var owner: (name: String, path: String?)?
            // Bare system executables are attributed to the app that launched them.
            if ident.bundle == nil, let ownerExe = ownerPath(of: row.pid), ownerExe != row.path {
                let o = Self.identity(for: ownerExe)
                owner = (o.name, o.bundle)
                ident = (ident.key + "|" + o.key, ident.name + " · " + o.name, nil)
            }
            var g = byKey[ident.key] ?? ProcessGroup(id: ident.key, name: ident.name, bundlePath: ident.bundle,
                                                     ownerName: owner?.name, ownerPath: owner?.path)
            g.cpu += row.cpu
            var procMemory = row.rss

            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(row.pid, RUSAGE_INFO_V4, $0) }
            } == 0
            if ok {
                procMemory = info.ri_phys_footprint
                g.diskKnown = true
                let cur = (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
                seenDisk[row.pid] = cur
                if let prev = prevPidDisk[row.pid], cur.0 >= prev.read, cur.1 >= prev.write {
                    g.diskRead += Double(cur.0 - prev.read) / interval
                    g.diskWrite += Double(cur.1 - prev.write) / interval
                }
            }
            g.memory += procMemory
            g.processes.append(ProcessDetail(id: row.pid, name: Self.shortName(row.path), cpu: row.cpu,
                                             memory: procMemory, elapsed: row.elapsed))
            byKey[ident.key] = g
        }
        prevPidDisk = seenDisk

        for key in byKey.keys {
            if byKey[key]!.cpu >= Self.idleCPUThreshold || lastActive[key] == nil {
                lastActive[key] = now
            }
            byKey[key]!.idleSince = byKey[key]!.cpu < Self.idleCPUThreshold ? lastActive[key] : nil
        }
        lastActive = lastActive.filter { byKey[$0.key] != nil }
        return Array(byKey.values)
    }
}
