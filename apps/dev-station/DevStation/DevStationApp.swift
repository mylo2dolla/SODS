import SwiftUI
import Foundation

@main
struct SODSApp: App {
    @MainActor
    init() {
        _ = BLEScanner.shared
        BLEScanner.configureDevStationLogging()
        Task.detached {
            await OUIStore.shared.loadPreferredIfNeeded(log: LogStore.shared)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandMenu("Nodes") {
                Button {
                    NotificationCenter.default.post(name: .connectNodeCommand, object: nil)
                } label: {
                    Image(systemName: "link.circle")
                }
                .help("Connect Node")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button {
                    NotificationCenter.default.post(name: .flashNodeCommand, object: nil)
                } label: {
                    Image(systemName: "bolt.circle")
                }
                .help("Flash Firmware")
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}
