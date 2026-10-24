// MenuBarController.swift
// The status item and the panel under it.
//
// The panel is a borderless NSPanel hosting PanelView (SwiftUI) instead of
// an NSMenu, because a menu closes on every click. The panel stays open until
// you click outside it, press Escape, or click the icon again, so you can pin
// a device and adjust its slider in one go.

import AppKit
import Combine
import SwiftUI
import os

private let log = Logger(subsystem: "com.mattmoglia.AudioPin", category: "MenuBarController")

@MainActor
final class MenuBarController: NSObject {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private let hostingController: NSHostingController<AnyView>
    private var hosting: NSView { hostingController.view }
    private let panelWidth: CGFloat = 320
    private var cancellable: AnyCancellable?
    private var clickMonitors: [Any] = []
    private let coffee = CoffeeWindow()
    private var coffeeObserver: NSObjectProtocol?

    private let cornerRadius: CGFloat = 11

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        // The controller never touches the window's size; open() and
        // resize(to:) place and size the panel by hand.
        hostingController.sizingOptions = []
        super.init()

        // Window chrome: transparent window, material background, rounded.
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 0.5
        material.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = material

        hostingController.rootView = AnyView(
            PanelView(onSizeChange: { [weak self] size in self?.resize(to: size) })
                .environmentObject(state)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: material.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.toolTip = "AudioPin"
        }
        updateIcon()

        coffeeObserver = NotificationCenter.default.addObserver(
            forName: .audioPinOpenCoffee, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openCoffee() }
        }
        // For testing: `AudioPin --coffee` opens the tip window at launch.
        if CommandLine.arguments.contains("--coffee") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openCoffee() }
        }

        // Keep the icon in sync with "Enforce pins" (fires before the change,
        // so hop to the next run-loop turn to read the new value).
        cancellable = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    /// A pushpin, so it isn't mistaken for the system Sound icon.
    /// Slashed when "Enforce pins" is off.
    private func updateIcon() {
        let name = state.enforcePins ? "pin.fill" : "pin.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AudioPin")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Close the panel and show the tip window under the icon.
    private func openCoffee() {
        close()
        let button = statusItem.button
        let anchor = button.flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? button?.window?.screen
        coffee.show(near: anchor, on: screen)
    }

    // MARK: - Open / close

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible { close() } else { open() }
    }

    private func open() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        state.refreshAndEnforce()

        // Ask SwiftUI how tall the content is at the panel's width, then hang
        // the panel under the icon, centered on it and kept inside the screen.
        var size = hostingController.sizeThatFits(in: NSSize(width: panelWidth, height: 10_000))
        size.width = panelWidth
        if size.height < 50 {
            // Not measured yet (first open can race layout): start with a
            // sensible height and let the SwiftUI size report correct it.
            log.info("Content not measured yet (\(size.height)); using placeholder height")
            size.height = 600
        }

        // Where to hang the panel. The user just clicked the icon, so the
        // mouse is on it: anchor to the mouse's column in the menu bar of the
        // screen the mouse is on. (The status bar window's own coordinates
        // have been wrong right after launch on multi-display setups.)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? buttonWindow.screen ?? NSScreen.main
        var anchor: NSRect
        if let screen {
            let menuBarBottom = screen.visibleFrame.maxY
            anchor = NSRect(x: mouse.x - 11, y: menuBarBottom, width: 22, height: screen.frame.maxY - menuBarBottom)
        } else {
            anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let visible = screen?.visibleFrame ?? anchor
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - 4
        log.info("Panel at \(x) \(y) size \(size.width)x\(size.height); anchor \(NSStringFromRect(anchor), privacy: .public)")
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        // Belt and braces: if anything nudged the window while it was being
        // shown for the first time, put it back where it belongs.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, abs(self.panel.frame.origin.x - frame.origin.x) > 1 || abs(self.panel.frame.origin.y - frame.origin.y) > 1 else { return }
            log.info("Panel moved to \(NSStringFromRect(self.panel.frame), privacy: .public) on show; restoring")
            self.panel.setFrameOrigin(frame.origin)
        }
        button.highlight(true)
        installClickMonitors()
    }

    private func close() {
        removeClickMonitors()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    /// Grow or shrink the panel in place (keeping its top edge) when the
    /// content changes, e.g. a new routed app adds rows.
    private func resize(to size: CGSize) {
        guard panel.isVisible, size.height > 0 else { return }
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 else { return }
        frame.origin.y = frame.maxY - size.height
        frame.size = NSSize(width: panelWidth, height: size.height)
        panel.setFrame(frame, display: true)
    }

    /// Close on any click outside the panel (in this app or any other) and
    /// on Escape. Clicking the status item itself is handled by the toggle.
    private func installClickMonitors() {
        removeClickMonitors()
        let masks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: masks, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: masks.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }   // Escape
                return event
            }
            if event.window !== self.panel, event.window !== self.statusItem.button?.window {
                self.close()
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors.removeAll()
    }
}
