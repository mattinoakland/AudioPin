// CoffeeWindow.swift
// "Buy me a coffee" without leaving the app: a small window, phone-sized,
// that shows the tip page from mattmoglia.com in embed mode (no site header
// or footer). Payment is handled there by Stripe; Apple Pay on the web works
// inside WKWebView on macOS, so a Mac with Apple Pay set up gets the real
// button. When the page reports success (it sets #paid in its URL), the
// window closes itself after a moment.
//
// Deliberately no script injection and no custom user agent: either one
// makes WebKit withhold Apple Pay from the page.

import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.mattmoglia.AudioPin", category: "CoffeeWindow")

@MainActor
final class CoffeeWindow: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var urlObservation: NSKeyValueObservation?

    private let size = NSSize(width: 420, height: 640)

    /// Shows the window (creating it on first use) under the menu bar icon.
    func show(near anchor: NSRect?, on screen: NSScreen?) {
        if window == nil { build() }
        guard let window else { return }

        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = (anchor?.midX ?? visible.midX) - size.width / 2
        x = min(max(x, visible.minX + 12), visible.maxX - size.width - 12)
        let y = (anchor?.minY ?? visible.maxY) - size.height - 8
        window.setFrame(NSRect(x: x, y: max(y, visible.minY + 12), width: size.width, height: size.height), display: true)

        // `defaults write com.mattmoglia.AudioPin coffeeURL <url>` overrides the
        // page for testing (e.g. adding ?debug=1).
        let url = UserDefaults.standard.string(forKey: "coffeeURL").flatMap(URL.init(string:)) ?? Links.coffeeEmbed
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView?.load(request)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Buy me a coffee"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = NSColor.windowBackgroundColor
        window.contentView = webView
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Close when the page says the payment went through.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            guard view.url?.fragment == "paid" else { return }
            log.info("Coffee paid; closing window")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.close() }
        }

        self.webView = webView
        self.window = window
    }

    // Links on the page that leave the tip flow open in the real browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // "Pay with Apple Pay in Safari": the page asks for the real browser.
        if url.query?.contains("browser=1") == true {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let kept = (comps?.queryItems ?? []).filter { $0.name != "browser" && $0.name != "embed" }
            comps?.queryItems = kept.isEmpty ? nil : kept
            NSWorkspace.shared.open(comps?.url ?? url)
            decisionHandler(.cancel)
            close()
            return
        }
        let isOurs = url.host == Links.coffeeEmbed.host && url.path.hasPrefix("/audiopin/coffee")
        let isStripe = (url.host ?? "").hasSuffix("stripe.com") || (url.host ?? "").hasSuffix("link.com")
        if isOurs || isStripe || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    // Stripe/Link may open popups (3-D Secure, Link sign-in); load them in place.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("Coffee page failed to load: \(error.localizedDescription, privacy: .public)")
    }
}
