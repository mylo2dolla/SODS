import Foundation
import AppKit

enum StoragePaths {
    static func sodsRootURL() -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let explicit = env["SODS_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            candidates.append(explicit)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/SODS-main")
        candidates.append(fm.currentDirectoryPath)

        for path in candidates {
            if isValidSODSRoot(path) {
                return URL(fileURLWithPath: path)
            }
        }

        var probe = fm.currentDirectoryPath
        for _ in 0..<6 {
            if isValidSODSRoot(probe) {
                return URL(fileURLWithPath: probe)
            }
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe { break }
            probe = parent
        }

        let fallback = URL(fileURLWithPath: candidates.first ?? "\(home)/SODS-main")
        LogStore.logAsync(.error, "Unable to validate SODS root. Falling back to \(fallback.path)")
        return fallback
    }

    static func sodsRootPath() -> String {
        sodsRootURL().path
    }

    static func inboxBase() -> URL {
        ensureStorageSubdir("inbox")
    }

    static func workspaceBase() -> URL {
        ensureStorageSubdir("workspace")
    }

    static func reportsBase() -> URL {
        ensureStorageSubdir("reports")
    }

    static func recordingsBase() -> URL {
        ensureStorageSubdir("recordings")
    }

    static func shipperBase() -> URL {
        ensureStorageSubdir(".shipper")
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

    private static func isValidSODSRoot(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        let required = [
            "\(path)/tools/sods",
            "\(path)/docs/tool-registry.json",
            "\(path)/firmware"
        ]
        return required.allSatisfy { fm.fileExists(atPath: $0) }
    }

    private static func ensureStorageSubdir(_ name: String) -> URL {
        let current = ensureSubdir(base: sodsRootURL(), name: name)
        migrateLegacySubdirIfNeeded(name: name, destination: current)
        return current
    }

    private static func migrateLegacySubdirIfNeeded(name: String, destination: URL) {
        let fm = FileManager.default
        let legacy = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("SODS")
            .appendingPathComponent(name)
        guard legacy.path != destination.path else { return }
        guard fm.fileExists(atPath: legacy.path) else { return }
        let hasDestinationItems = (try? fm.contentsOfDirectory(atPath: destination.path).isEmpty == false) ?? false
        guard !hasDestinationItems else { return }
        do {
            let items = try fm.contentsOfDirectory(atPath: legacy.path)
            for item in items {
                let src = legacy.appendingPathComponent(item)
                let dst = destination.appendingPathComponent(item)
                if fm.fileExists(atPath: dst.path) { continue }
                try fm.moveItem(at: src, to: dst)
            }
            LogStore.logAsync(.info, "Migrated legacy \(name) data from \(legacy.path) to \(destination.path)")
        } catch {
            LogStore.logAsync(.error, "Failed migrating legacy \(name) data: \(error.localizedDescription)")
        }
    }
}
