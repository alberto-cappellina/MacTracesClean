import Foundation

struct InventoryItem: Identifiable {
    let id = UUID()
    var path: String
    var kind: String
    var size: Int64
    var isDirectory: Bool
}

enum InventoryEngine {

    /// Files/paths that the given area would act on, sorted by absolute path.
    static func items(for area: CleanArea, _ cfg: CleanConfigSnapshot) -> [InventoryItem] {
        let list: [InventoryItem]
        switch area {
        case .browserHistory: list = browser(cfg)
        case .shellHistory:   list = shell()
        case .quicklookCache: list = quicklook()
        case .downloadsOld:   list = downloads(cfg)
        case .orphanAppData:  list = orphans()
        case .userCaches, .appLogs, .xcodeJunk, .devCaches,
             .iosBackups, .mailAttachments, .trashBins:
            list = folderItems(area)
        }
        return list.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func item(_ url: URL, kind: String? = nil, size: Int64? = nil) -> InventoryItem {
        let dir = Helpers.isDir(url)
        let k: String
        if let kind = kind {
            k = kind
        } else if dir {
            k = "Folder"
        } else {
            let ext = url.pathExtension
            k = ext.isEmpty ? "File" : ext.uppercased()
        }
        return InventoryItem(path: url.path, kind: k,
                             size: size ?? Helpers.pathSize(url), isDirectory: dir)
    }

    private static func browser(_ cfg: CleanConfigSnapshot) -> [InventoryItem] {
        var out: [InventoryItem] = []
        if cfg.browserTargets.contains("safari") {
            let db = HOME.appendingPathComponent("Library/Safari/History.db")
            if Helpers.exists(db) { out.append(item(db, kind: "Safari database")) }
        }
        if cfg.browserTargets.contains("chromium") {
            for base in BrowserPaths.chromiumBases {
                let root = HOME.appendingPathComponent(base.rel)
                guard Helpers.isDir(root) else { continue }
                for (_, hist) in BrowserPaths.historyFiles(in: root) {
                    out.append(item(hist, kind: "\(base.name) database"))
                }
            }
        }
        if cfg.browserTargets.contains("firefox") {
            let base = HOME.appendingPathComponent("Library/Application Support/Firefox/Profiles")
            if Helpers.isDir(base) {
                for profile in Helpers.contents(base) where Helpers.isDir(profile) {
                    let places = profile.appendingPathComponent("places.sqlite")
                    if Helpers.exists(places) { out.append(item(places, kind: "Firefox database")) }
                }
            }
        }
        return out
    }

    private static func shell() -> [InventoryItem] {
        var out: [InventoryItem] = []
        for name in [".zsh_history", ".bash_history"] {
            let f = HOME.appendingPathComponent(name)
            if Helpers.exists(f) { out.append(item(f, kind: "Shell history")) }
        }
        return out
    }

    private static func quicklook() -> [InventoryItem] {
        let d = HOME.appendingPathComponent("Library/Caches/com.apple.QuickLook.thumbnailcache")
        guard Helpers.isDir(d) else { return [] }
        var out: [InventoryItem] = []
        if let en = FileManager.default.enumerator(at: d,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if v?.isRegularFile == true {
                    out.append(item(f, size: Int64(v?.fileSize ?? 0)))
                }
                if out.count >= 5000 { break }
            }
        }
        return out
    }

    private static func downloads(_ cfg: CleanConfigSnapshot) -> [InventoryItem] {
        let d = HOME.appendingPathComponent("Downloads")
        guard Helpers.isDir(d) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - Double(cfg.downloadsOlderThanDays) * 86400
        return Helpers.contents(d)
            .filter { $0.lastPathComponent != ".DS_Store" && ScanEngine.mtime($0) < cutoff }
            .map { item($0) }
    }

    private static func folderItems(_ area: CleanArea) -> [InventoryItem] {
        var out: [InventoryItem] = []
        for root in CleanEngine.cleanRoots(area) where Helpers.isDir(root) {
            for c in Helpers.contents(root) where c.lastPathComponent != ".DS_Store" {
                out.append(item(c))
            }
        }
        return out
    }

    private static func orphans() -> [InventoryItem] {
        OrphanFinder.find(cap: 1000)
            .filter { $0.confidence == .high }
            .map { item($0.path, size: $0.size) }
    }
}
