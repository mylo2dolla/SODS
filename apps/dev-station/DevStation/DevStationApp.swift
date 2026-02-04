import SwiftUI
import Foundation

@main
struct SODSApp: App {
    @MainActor
    init() {
        _ = BLEScanner.shared
        Task.detached {
            await OUIStore.shared.loadPreferredIfNeeded(log: LogStore.shared)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1200, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Nodes") {
                Button("Connect / Flash Node") {
                    NotificationCenter.default.post(name: .flashNodeCommand, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}
