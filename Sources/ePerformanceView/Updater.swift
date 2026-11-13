import AppKit
import Foundation

/// Checks GitHub Releases for a newer version and replaces the installed app in place.
/// Only the release metadata and the release zip are fetched; nothing about this Mac is sent.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    static let repository = "elisoares/ePerformanceView"
    /// Automatic checks are light (one small JSON request); once a day is enough.
    static let checkInterval: TimeInterval = 24 * 3600

    @Published private(set) var state: State = .idle
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func startChecking() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        if case .checking = state { return }
        if case .installing = state { return }
        state = .checking
        Task {
            do {
                let release = try await Self.latestRelease()
                state = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                state = .failed("Não foi possível verificar: \(error.localizedDescription)")
            }
        }
    }

    /// Downloads the release zip, checks it is this app, then swaps the bundle and relaunches.
    func install(_ release: Release) {
        state = .installing(release)
        Task {
            do {
                let (zip, _) = try await URLSession.shared.download(from: release.zipURL)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("ePerformanceView-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }),
                      Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw UpdateError("o pacote baixado não é o ePerformance View")
                }
                Self.replaceAndRelaunch(with: newApp)
            } catch {
                state = .failed("Falha ao atualizar: \(error.localizedDescription)")
            }
        }
    }

    // MARK: GitHub

    private struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ePerformanceView-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix(".zip") }),
              let zipURL = URL(string: zip) else {
            throw UpdateError("resposta inesperada do GitHub")
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zipURL: zipURL, pageURL: page)
    }

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.3").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Install

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(path) terminou com erro \(p.terminationStatus)") }
    }

    /// A detached shell waits for this process to exit, swaps the bundle and opens the new one.
    private static func replaceAndRelaunch(with newApp: URL) {
        let target = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1" && /usr/bin/ditto "$2" "$1" && /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", target, newApp.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
