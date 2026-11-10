import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Text(state.statusText)
        Button(state.isRecording ? "Stop Listening" : "Start Listening") {
            state.toggleRecording()
        }
        .keyboardShortcut("l")
        .disabled(state.isBusy)

        Divider()
        Toggle("Show Overlay", isOn: $settings.overlayVisible)
        Toggle("Overlay Click-through", isOn: $settings.overlayClickThrough)

        Divider()
        Button("History…") { WindowManager.shared.showHistory() }
            .keyboardShortcut("h")
        Button("Settings…") { WindowManager.shared.showSettings() }
            .keyboardShortcut(",")

        Divider()
        Button("Quit Cabin") {
            Task {
                await state.stop()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }
}
