import AppKit
import SwiftUI

@main
struct CabinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(settings)
        } label: {
            Image(systemName: state.isRecording ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overlay = OverlayController(state: AppState.shared, settings: AppSettings.shared)

        let hasKey = AppSettings.shared.llmProvider == .none
            || KeychainStore.read(AppSettings.shared.llmProvider.keychainAccount) != nil
        if !hasKey {
            WindowManager.shared.showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
