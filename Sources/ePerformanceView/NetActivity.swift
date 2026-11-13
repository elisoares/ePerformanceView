import CoreWLAN
import Darwin
import Foundation

/// Per-process network throughput (from `nettop`) and internet latency (from `ping`).
/// Runs on its own queue because `nettop` takes a few seconds to answer; it only waits, it does not spin.
final class NetActivity: @unchecked Sendable { // state touched only from `queue`
    struct Update {
        let ratesByPid: [pid_t: (down: Double, up: Double)]
        let pingMs: Double?
        let wifi: WiFiInfo?
    }

    private let queue = DispatchQueue(label: "eperformanceview.net", qos: .utility)
    private var previous: [pid_t: (down: UInt64, up: UInt64)] = [:]
    private var previousAt: Date?
    private var lastPing = Date.distantPast
    private var pingMs: Double?
    private var wifi: WiFiInfo?
    private var running = false

    /// How often the internet latency is measured.
    static let pingInterval: TimeInterval = 30

    func start(onUpdate: @escaping @Sendable (Update) -> Void) {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.loop(onUpdate)
        }
    }

    private func loop(_ onUpdate: @escaping @Sendable (Update) -> Void) {
        let now = Date()
        let counters = Self.readNettop()
        var rates: [pid_t: (down: Double, up: Double)] = [:]
        if let at = previousAt {
            let dt = max(1, now.timeIntervalSince(at))
            for (pid, cur) in counters {
                guard let prev = previous[pid], cur.down >= prev.down, cur.up >= prev.up else { continue }
                let r = (down: Double(cur.down - prev.down) / dt, up: Double(cur.up - prev.up) / dt)
                if r.down > 0 || r.up > 0 { rates[pid] = r }
            }
        }
        previous = counters
        previousAt = now

        if now.timeIntervalSince(lastPing) >= Self.pingInterval {
            lastPing = now
            pingMs = Self.ping()
            wifi = WiFiInfo.current()
        }
        onUpdate(Update(ratesByPid: rates, pingMs: pingMs, wifi: wifi))
        queue.asyncAfter(deadline: .now() + 1) { self.loop(onUpdate) }
    }

    /// `nettop -P -L 1 -x -J bytes_in,bytes_out` prints "name.pid,bytes_in,bytes_out," per process.
    /// Only Wi-Fi and wired interfaces count: loopback (local VMs, tunnels to localhost) never reaches the internet.
    private static func readNettop() -> [pid_t: (down: UInt64, up: UInt64)] {
        guard let text = run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-t", "wifi", "-t", "wired", "-J", "bytes_in,bytes_out"]) else { return [:] }
        var result: [pid_t: (down: UInt64, up: UInt64)] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let down = UInt64(fields[1]), let up = UInt64(fields[2]) else { continue }
            result[pid] = (down, up)
        }
        return result
    }

    private static func ping() -> Double? {
        guard let text = run("/sbin/ping", ["-c", "1", "-t", "2", "-q", "1.1.1.1"]) else { return nil }
        // "round-trip min/avg/max/stddev = 12.345/12.345/12.345/0.000 ms"
        guard let line = text.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
              let values = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces).split(separator: "/"),
              values.count >= 2 else { return nil }
        return Double(values[1])
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// Radio link of the active Wi-Fi interface (no traffic involved, read from CoreWLAN).
struct WiFiInfo {
    let generation: String?     // "Wi-Fi 6"
    let band: String?           // "5 GHz"
    let channel: Int?
    let rssi: Int               // dBm
    let noise: Int              // dBm
    let txRateMbps: Double

    var signalLabel: String {
        rssi >= -55 ? "ótimo" : rssi >= -67 ? "bom" : rssi >= -75 ? "razoável" : "fraco"
    }
    var signalLevel: Level { rssi >= -67 ? .ok : rssi >= -75 ? .warn : .critical }
    var shortName: String { generation.map { $0.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "") } ?? "wifi" }

    static func current() -> WiFiInfo? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn(), i.rssiValue() != 0 else { return nil }
        let gen: String? = switch i.activePHYMode().rawValue {
        case 4: "Wi-Fi 4"
        case 5: "Wi-Fi 5"
        case 6: "Wi-Fi 6"
        case 7: "Wi-Fi 7"
        default: nil
        }
        let band: String? = switch i.wlanChannel()?.channelBand.rawValue {
        case 1: "2,4 GHz"
        case 2: "5 GHz"
        case 3: "6 GHz"
        default: nil
        }
        return WiFiInfo(generation: gen, band: band, channel: i.wlanChannel()?.channelNumber,
                        rssi: i.rssiValue(), noise: i.noiseMeasurement(), txRateMbps: i.transmitRate())
    }
}

/// Link capacity measured with Apple's `networkQuality` (download then upload, sequentially).
struct SpeedResult: Codable {
    let downMbps: Double
    let upMbps: Double
    let latencyMs: Double?
    let date: Date
}

enum SpeedTest {
    /// Blocking; call off the main thread. Takes ~20-40 s and transfers a few hundred MB on a fast link.
    static func run() -> SpeedResult? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        p.arguments = ["-s", "-c", "-M", "40"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dl = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let ul = (json["ul_throughput"] as? NSNumber)?.doubleValue, dl > 0 else { return nil }
        return SpeedResult(downMbps: dl / 1_000_000, upMbps: ul / 1_000_000,
                           latencyMs: (json["base_rtt"] as? NSNumber)?.doubleValue, date: Date())
    }
}
