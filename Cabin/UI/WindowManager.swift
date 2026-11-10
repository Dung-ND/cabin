import AppKit
import SwiftUI

/// Opens regular windows (History, Settings) for this menu-bar app and shows the Dock icon while they're open.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func showHistory() {
        show(id: "history", title: "Cabin — History", size: NSSize(width: 980, height: 640)) {
            HistoryView()
                .environmentObject(AppState.shared)
                .environmentObject(AppSettings.shared)
        }
    }

    func showSettings() {
        show(id: "settings", title: "Cabin Settings", size: NSSize(width: 560, height: 520)) {
            SettingsView()
                .environmentObject(AppState.shared)
                .environmentObject(AppSettings.shared)
        }
    }

    private func show<Content: View>(id: String, title: String, size: NSSize, content: () -> Content) {
        NSApp.setActivationPolicy(.regular)
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Cabin-\(id)")
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        let othersVisible = windows.values.contains { $0 !== closing && $0.isVisible }
        if !othersVisible {
            // Back to a pure menu-bar app.
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
