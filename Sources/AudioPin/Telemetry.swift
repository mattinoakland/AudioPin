// Telemetry.swift
// One small anonymous ping, on launch and once a day, and the reply tells us
// whether a newer version exists.
//
// What leaves the Mac: a random install ID (made once, stored in
// UserDefaults), the app version and build, the macOS version, the CPU
// architecture, and the Mac's region setting (two-letter country code).
// Nothing about devices, apps, audio, or the person. The country comes from
// the region setting, not the IP address or location services.
//
// "Send anonymous usage stats" in the panel turns the ping off. The version
// check still runs when it's off, with no install ID attached.

import Foundation
import os

private let log = Logger(subsystem: "com.mattmoglia.AudioPin", category: "Telemetry")

/// What the server says back.
struct UpdateInfo: Equatable {
    let version: String
    let downloadURL: URL
    let notes: String?
}

@MainActor
final class Telemetry {
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private let interval: TimeInterval = 24 * 60 * 60

    private enum Key {
        static let installID = "installID"
        static let lastPing = "lastPingAt"
        static let enabled = "telemetryEnabled"
    }

    /// Called with update info (or nil) after each check.
    var onResult: ((UpdateInfo?) -> Void)?

    var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Stable random ID, created on first run.
    var installID: String {
        if let id = defaults.string(forKey: Key.installID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.installID)
        return id
    }

    /// Ping now if it's been a day (or never), then keep checking daily.
    func start() {
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let last = defaults.object(forKey: Key.lastPing) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        Task { await ping() }
    }

    /// Send the ping (or just ask for the latest version when stats are off).
    func ping() async {
        var payload: [String: Any] = [
            "version": AppInfo.version,
            "build": AppInfo.build,
            "macos": AppInfo.macOSVersion,
            "arch": AppInfo.architecture,
        ]
        if isEnabled {
            payload["installId"] = installID
            payload["region"] = Locale.current.region?.identifier ?? ""
        }

        var request = URLRequest(url: Links.api.appendingPathComponent("ping"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.error("Ping failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            defaults.set(Date(), forKey: Key.lastPing)
            let update = Self.parseUpdate(data)
            log.info("Ping ok; latest=\(update?.version ?? "none", privacy: .public)")
            onResult?(update)
        } catch {
            // Offline is normal; try again next hour.
            log.info("Ping skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads {"latest": {"version": "1.2", "url": "...", "notes": "..."}} and
    /// returns it only if that version is newer than this one.
    private static func parseUpdate(_ data: Data) -> UpdateInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = json["latest"] as? [String: Any],
              let version = latest["version"] as? String,
              let urlString = latest["url"] as? String,
              let url = URL(string: urlString),
              isNewer(version, than: AppInfo.version)
        else { return nil }
        return UpdateInfo(version: version, downloadURL: url, notes: latest["notes"] as? String)
    }

    /// "1.10" is newer than "1.9"; compares number by number.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
