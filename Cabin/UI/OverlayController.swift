import AppKit
import Combine
import SwiftUI

/// Always-on-top, non-activating panel that floats over every Space and full-screen app.
final class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 220, height: 120)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private let panel: OverlayPanel
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState, settings: AppSettings) {
        self.settings = settings
        panel = OverlayPanel(size: NSSize(width: settings.overlayWidth, height: settings.overlayHeight))
        super.init()

        let root = OverlayView()
            .environmentObject(state)
            .environmentObject(settings)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.delegate = self

        if !panel.setFrameUsingName("CabinOverlay") {
            positionTopRight()
        }
        panel.setFrameAutosaveName("CabinOverlay")
        applySize()

        settings.$overlayOpacity
            .sink { [weak self] value in self?.panel.alphaValue = CGFloat(min(1, max(0.15, value))) }
            .store(in: &cancellables)
        settings.$overlayClickThrough
            .sink { [weak self] value in self?.panel.ignoresMouseEvents = value }
            .store(in: &cancellables)
        settings.$overlayVisible
            .sink { [weak self] visible in
                if visible { self?.panel.orderFrontRegardless() } else { self?.panel.orderOut(nil) }
            }
            .store(in: &cancellables)
        settings.$overlayWidth.combineLatest(settings.$overlayHeight)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applySize() }
            .store(in: &cancellables)
    }

    private func applySize() {
        let target = NSSize(width: settings.overlayWidth, height: settings.overlayHeight)
        let current = panel.frame.size
        guard abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1 else { return }
        var frame = panel.frame
        // Keep the top-left corner fixed while resizing.
        frame.origin.y += frame.size.height - target.height
        frame.size = target
        panel.setFrame(frame, display: true, animate: false)
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20))
    }

    // Keep Settings sliders in sync when the user drags the panel edges.
    func windowDidEndLiveResize(_ notification: Notification) {
        let size = panel.frame.size
        if abs(settings.overlayWidth - size.width) > 1 { settings.overlayWidth = size.width.rounded() }
        if abs(settings.overlayHeight - size.height) > 1 { settings.overlayHeight = size.height.rounded() }
    }
}
