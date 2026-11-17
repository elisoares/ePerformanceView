import Foundation
import IOKit

/// Minimal read-only client for the AppleSMC user client (fan speeds and temperatures).
final class SMC {
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    // Explicit padding keeps the Swift layout identical to the 12-byte C struct.
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attr: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct Param {
        var key: UInt32 = 0
        var vers = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0

    init?() {
        guard MemoryLayout<Param>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<Param>.stride, &output, &size)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    /// Size and type never change for a key, so they are asked once; each later read is a single call.
    private var keyInfoCache: [String: KeyInfo] = [:]

    /// Returns the raw bytes and the type code of an SMC key.
    private func read(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        let info: KeyInfo
        if let cached = keyInfoCache[key] {
            info = cached
        } else {
            var infoReq = Param(); infoReq.key = Self.fourCC(key); infoReq.data8 = 9
            guard let reply = call(&infoReq) else { return nil }
            info = reply.keyInfo
            keyInfoCache[key] = info
        }
        var readReq = Param(); readReq.key = Self.fourCC(key); readReq.keyInfo.dataSize = info.dataSize; readReq.data8 = 5
        guard let value = call(&readReq) else { return nil }
        let b = value.bytes
        return (info.dataType, [b.0, b.1, b.2, b.3])
    }

    private func number(_ key: String) -> Double? {
        guard let v = read(key) else { return nil }
        switch v.type {
        case Self.fourCC("flt "):
            let bits = UInt32(v.bytes[0]) | (UInt32(v.bytes[1]) << 8) | (UInt32(v.bytes[2]) << 16) | (UInt32(v.bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case Self.fourCC("fpe2"):
            return Double((UInt16(v.bytes[0]) << 8) | UInt16(v.bytes[1])) / 4.0
        case Self.fourCC("ui8 "):
            return Double(v.bytes[0])
        default:
            return nil
        }
    }

    struct Fan: Identifiable { let id: Int; let rpm: Double; let min: Double; let max: Double
        /// Share of the maximum speed (0 when stopped).
        var fraction: Double { max > 0 ? Swift.max(0, Swift.min(1, rpm / max)) : 0 }
    }

    /// Hottest reading per area, in °C; nil when this Mac exposes no sensor for it.
    struct Temperatures: Equatable {
        var cpu: Double?
        var gpu: Double?
        var ssd: Double?
        var battery: Double?
    }

    /// Temperature keys grouped by area, discovered once: key names differ between Mac models,
    /// so they are listed from the SMC instead of hard-coded.
    private lazy var temperatureKeys: [WritableKeyPath<Temperatures, Double?>: [String]] = {
        var groups: [WritableKeyPath<Temperatures, Double?>: [String]] = [:]
        for key in allKeys() where key.hasPrefix("T") {
            let area: WritableKeyPath<Temperatures, Double?>? =
                key.hasPrefix("Tp") || key.hasPrefix("Te") ? \.cpu    // performance and efficiency cores
                : key.hasPrefix("Tg") ? \.gpu
                : key.hasPrefix("TH") ? \.ssd                         // NAND/SSD
                : key.hasPrefix("TB") ? \.battery
                : nil
            if let area { groups[area, default: []].append(key) }
        }
        return groups
    }()

    /// Hottest sensors per area from the last full scan; the usual read touches only these.
    private var hotKeys: [WritableKeyPath<Temperatures, Double?>: [String]] = [:]
    private var readsSinceScan = 0
    /// Every key is read once per this many calls (~1 min at the 3 s sample rate); a full read takes ~30 ms.
    private static let fullScanEvery = 20
    private static let hotKeysPerArea = 6

    func temperatures() -> Temperatures {
        let fullScan = hotKeys.isEmpty || readsSinceScan >= Self.fullScanEvery
        readsSinceScan = fullScan ? 0 : readsSinceScan + 1
        var t = Temperatures()
        for (area, keys) in fullScan ? temperatureKeys : hotKeys {
            // Unused sensors read 0 or nonsense; keep plausible die/board values only.
            let readings = keys.compactMap { key in number(key).map { (key, $0) } }.filter { $0.1 > 5 && $0.1 < 130 }
            t[keyPath: area] = readings.map(\.1).max()
            if fullScan {
                hotKeys[area] = readings.sorted { $0.1 > $1.1 }.prefix(Self.hotKeysPerArea).map(\.0)
            }
        }
        return t
    }

    /// Every key name, by index ("#KEY" holds the count as a big-endian ui32).
    private func allKeys() -> [String] {
        guard let count = read("#KEY").map({ $0.bytes.reduce(0) { ($0 << 8) | UInt32($1) } }) else { return [] }
        return (0..<count).compactMap { i in
            var req = Param(); req.data8 = 8; req.data32 = i
            guard let out = call(&req) else { return nil }
            let k = out.key
            return String(bytes: [UInt8(k >> 24 & 0xFF), UInt8(k >> 16 & 0xFF), UInt8(k >> 8 & 0xFF), UInt8(k & 0xFF)], encoding: .ascii)
        }
    }

    func fans() -> [Fan] {
        let count = Int(number("FNum") ?? 0)
        return (0..<count).compactMap { i in
            guard let rpm = number("F\(i)Ac") else { return nil }
            return Fan(id: i, rpm: rpm, min: number("F\(i)Mn") ?? 0, max: number("F\(i)Mx") ?? 0)
        }
    }
}
