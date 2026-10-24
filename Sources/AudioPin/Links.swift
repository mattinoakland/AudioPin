// Links.swift
// Every outside URL the app opens or talks to, in one place.

import Foundation

enum Links {
    /// Matt's site, credited in the panel.
    static let site = URL(string: "https://mattmoglia.com")!
    /// The app's own page: download, install help, release notes.
    static let appPage = URL(string: "https://mattmoglia.com/audiopin")!
    /// "Buy me a coffee": the tip page. The app shows it in its own small
    /// window (embed mode); this plain URL is the fallback for a browser.
    static let coffee = URL(string: "https://mattmoglia.com/audiopin/coffee")!
    static let coffeeEmbed = URL(string: "https://mattmoglia.com/audiopin/coffee?embed=1")!
    /// Feedback goes straight to Matt's inbox.
    static let feedbackEmail = "hi@mattmoglia.com"
    /// Anonymous usage ping + "is there a newer version" check (see Telemetry).
    static let api = URL(string: "https://mattmoglia.com/api/audiopin")!

    /// A mailto: link with the version and macOS details filled in, so the
    /// person doesn't have to look them up.
    static var feedbackMailto: URL {
        let subject = "AudioPin \(AppInfo.version) feedback"
        let body = "\n\n—\nAudioPin \(AppInfo.version) (\(AppInfo.build)) on macOS \(AppInfo.macOSVersion), \(AppInfo.architecture)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url!
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
