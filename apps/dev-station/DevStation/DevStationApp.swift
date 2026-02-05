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
        }
        .commands {
            CommandMenu("Nodes") {
                Button("Connect Node") {
                    NotificationCenter.default.post(name: .connectNodeCommand, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Flash Firmware") {
                    NotificationCenter.default.post(name: .flashNodeCommand, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}
