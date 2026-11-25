import AppKit
import SwiftUI

/// The menu bar icon and the Control Center-style panel that drops down from it.
@MainActor
final class StatusPanel: NSObject {
    private let model: MixerModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: Panel
    private let hosting: NSHostingController<MixerView>
    private var monitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private var isOpen = false
    private var closedAt = Date.distantPast

    private final class Panel: NSPanel {
        var onCancel: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel() }
    }

    init(model: MixerModel) {
        self.model = model
        hosting = NSHostingController(rootView: MixerView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        statusItem.autosaveName = "SoundSystem"
        statusItem.button?.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "App Volumes")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)

        let glass = NSGlassEffectView()
        glass.cornerRadius = 24
        glass.contentView = hosting.view
        panel.contentView = glass
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false // the app is rarely active; outside clicks close the panel instead
        panel.animationBehavior = .utilityWindow
        panel.onCancel = { [weak self] in self?.close() }

        sizeObservation = hosting.observe(\.preferredContentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(close), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func toggle() {
        // A click on the icon while open may reach the outside-click monitor first.
        if isOpen { close() } else if Date().timeIntervalSince(closedAt) > 0.25 { open() }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        model.panelDidOpen()
        hosting.view.layoutSubtreeIfNeeded()
        layout()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    @objc func close() {
        guard isOpen else { return }
        isOpen = false
        closedAt = Date()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.panelDidClose()
    }

    /// Keeps the panel hanging from the icon as rows come and go.
    private func layout() {
        let size = hosting.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        let anchor = statusItem.button?.window?.frame ?? .zero
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let top = min(anchor.minY > 0 ? anchor.minY : visible.maxY, visible.maxY) - 6
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}
