import Foundation
import AppKit

enum StoragePaths {
    static func inboxBase() -> URL {
        ensureDir(homeRelative: "SODS/inbox")
    }

    static func workspaceBase() -> URL {
        ensureDir(homeRelative: "SODS/workspace")
    }

    static func reportsBase() -> URL {
        ensureDir(homeRelative: "SODS/reports")
    }

    static func shipperBase() -> URL {
        ensureDir(homeRelative: "SODS/.shipper")
    }

    static func inboxSubdir(_ name: String) -> URL {
        ensureSubdir(base: inboxBase(), name: name)
    }

    static func workspaceSubdir(_ name: String) -> URL {
        ensureSubdir(base: workspaceBase(), name: name)
    }

    static func reportsSubdir(_ name: String) -> URL {
        ensureSubdir(base: reportsBase(), name: name)
    }

    static func ensureDir(homeRelative: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(homeRelative)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            LogStore.logAsync(.error, "Failed to create directory \(dir.path): \(error.localizedDescription)")
        }
        return dir
    }

    static func ensureSubdir(base: URL, name: String) -> URL {
        let dir = base.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            LogStore.logAsync(.error, "Failed to create directory \(dir.path): \(error.localizedDescription)")
        }
        return dir
    }

    static func revealResourcesFolder() {
        if let url = Bundle.main.resourceURL {
            NSWorkspace.shared.open(url)
        }
    }
}
