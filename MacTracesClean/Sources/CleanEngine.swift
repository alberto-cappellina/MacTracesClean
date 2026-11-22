import Foundation

enum CleanEngine {

    static func run(_ cfg: CleanConfigSnapshot, apply: Bool) -> [CleanResult] {
        let dryRun = !apply
        var backupRoot: URL? = nil
        if apply && cfg.backup {
            let root = HOME.appendingPathComponent("MacTracesClean_backups").appendingPathComponent(Helpers.stamp())
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            backupRoot = root
        }

        var results: [CleanResult] = []
        for area in CleanArea.allCases where cfg.enabled.contains(area) {
            switch area {
            case .browserHistory: results.append(browserHistory(cfg, dryRun, backupRoot))
            case .shellHistory:   results.append(shellHistory(cfg, dryRun, backupRoot))
            case .quicklookCache: results.append(quicklookCache(dryRun))
            case .downloadsOld:   results.append(downloadsOld(cfg, dryRun))
            case .orphanAppData:  results.append(orphanAppData(dryRun))
            case .userCaches, .appLogs, .xcodeJunk, .devCaches,
                 .iosBackups, .mailAttachments, .trashBins:
                results.append(folderClean(area, dryRun))
            }
        }
        return results
    }

    // MARK: SQL delete helper

    /// Returns (affectedCount, message).
    private static func sqlDelete(_ db: URL, tables: [String], statements: [String],
                                  dryRun: Bool, backup: URL?) -> (Int, String) {
        guard Helpers.exists(db) else { return (0, "not present") }
        var total = 0
        var readable = false
        for t in tables {
            if let c = SQLiteDB.count(db, table: t) { total += c; readable = true }
        }
        if !readable { return (0, "not readable (needs Full Disk Access or a closed browser)") }
        if dryRun { return (total, "\(total) rows would be deleted (dry-run)") }
        Helpers.backupFile(db, into: backup)
        do {
            try SQLiteDB.execute(db, statements)
            return (total, "\(total) rows deleted")
        } catch SQLiteError.locked {
            return (0, "DB locked: close the browser and try again")
        } catch {
            return (0, "error: \(error)")
        }
    }

    // MARK: Cleaners

    static func browserHistory(_ cfg: CleanConfigSnapshot, _ dryRun: Bool, _ backup: URL?) -> CleanResult {
        var r = CleanResult(area: .browserHistory)
        let t = cfg.browserTargets

        if t.contains("safari") {
            let (n, msg) = sqlDelete(
                HOME.appendingPathComponent("Library/Safari/History.db"),
                tables: ["history_visits", "history_items"],
                statements: ["DELETE FROM history_visits", "DELETE FROM history_items"],
                dryRun: dryRun, backup: backup)
            r.removed += n; r.log("Safari: \(msg)")
        }
        if t.contains("chromium") {
            for base in BrowserPaths.chromiumBases {
                let root = HOME.appendingPathComponent(base.rel)
                guard Helpers.isDir(root) else { continue }
                for (profile, hist) in BrowserPaths.historyFiles(in: root) {
                    let (n, msg) = sqlDelete(hist, tables: ["visits", "urls"],
                        statements: ["DELETE FROM visits", "DELETE FROM urls"],
                        dryRun: dryRun, backup: backup)
                    r.removed += n
                    let tag = profile.isEmpty ? base.name : "\(base.name)/\(profile)"
                    r.log("\(tag): \(msg)")
                }
            }
        }
        if t.contains("firefox") {
            let base = HOME.appendingPathComponent("Library/Application Support/Firefox/Profiles")
            if Helpers.isDir(base) {
                for profile in Helpers.contents(base) where Helpers.isDir(profile) {
                    let places = profile.appendingPathComponent("places.sqlite")
                    guard Helpers.exists(places) else { continue }
                    let (n, msg) = sqlDelete(places, tables: ["moz_historyvisits"],
                        statements: ["DELETE FROM moz_historyvisits"],
                        dryRun: dryRun, backup: backup)
                    r.removed += n; r.log("Firefox/\(profile.lastPathComponent): \(msg)")
                }
            }
        }
        if r.messages.isEmpty { r.log("no browser found") }
        return r
    }

    static func shellHistory(_ cfg: CleanConfigSnapshot, _ dryRun: Bool, _ backup: URL?) -> CleanResult {
        var r = CleanResult(area: .shellHistory)
        let secretRe = try! NSRegularExpression(
            pattern: "(password|passwd|token|secret|api[_-]?key|-p\\s|AWS_|BEARER|PRIVATE|sk-[A-Za-z0-9]|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20})",
            options: [.caseInsensitive])
        for name in [".zsh_history", ".bash_history"] {
            let f = HOME.appendingPathComponent(name)
            guard Helpers.exists(f) else { continue }
            guard let data = try? Data(contentsOf: f) else { r.log("\(name): not readable"); continue }
            let raw = String(decoding: data, as: UTF8.self)
            let lines = raw.components(separatedBy: "\n")
            let newLines: [String]
            let toRemove: Int
            if cfg.shellMode == .all {
                toRemove = lines.count
                newLines = []
            } else {
                newLines = lines.filter { !ScanEngine.matches(secretRe, $0) }
                toRemove = lines.count - newLines.count
            }
            r.removed += toRemove
            if dryRun { r.log("\(name): \(toRemove) lines would be removed (dry-run)"); continue }
            if toRemove == 0 { r.log("\(name): no lines to remove"); continue }
            Helpers.backupFile(f, into: backup)
            do {
                try newLines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
                r.log("\(name): \(toRemove) lines removed")
            } catch {
                r.log("\(name): write error (\(error))")
            }
        }
        if r.messages.isEmpty { r.log("no shell history file found") }
        return r
    }

    static func quicklookCache(_ dryRun: Bool) -> CleanResult {
        var r = CleanResult(area: .quicklookCache)
        let d = HOME.appendingPathComponent("Library/Caches/com.apple.QuickLook.thumbnailcache")
        guard Helpers.isDir(d) else { r.log("cache not present"); return r }
        var files: [URL] = []
        if let en = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in en {
                if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    files.append(f)
                }
            }
        }
        r.removed = files.count
        if dryRun { r.log("\(files.count) cache files would be removed (dry-run)"); return r }
        var errors = 0
        for f in files { if (try? FileManager.default.removeItem(at: f)) == nil { errors += 1 } }
        r.log("\(files.count - errors) files removed" + (errors > 0 ? ", \(errors) errors" : ""))
        return r
    }

    static func downloadsOld(_ cfg: CleanConfigSnapshot, _ dryRun: Bool) -> CleanResult {
        var r = CleanResult(area: .downloadsOld)
        let days = cfg.downloadsOlderThanDays
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
        let d = HOME.appendingPathComponent("Downloads")
        guard Helpers.isDir(d) else { r.log("Downloads folder not found"); return r }
        let old = Helpers.contents(d).filter {
            $0.lastPathComponent != ".DS_Store" && ScanEngine.mtime($0) < cutoff
        }
        r.removed = old.count
        if dryRun {
            for p in old.prefix(20) { r.log("→ Trash: \(p.lastPathComponent) (dry-run)") }
            r.log("total: \(old.count) items older than \(days) days")
            return r
        }
        var moved = 0
        for p in old { if Helpers.moveToTrash(p) { moved += 1 } else { r.log("error on \(p.lastPathComponent)") } }
        r.log("\(moved) items moved to the Trash (recoverable)")
        return r
    }

    // MARK: Directory-based cleaners (CleanMyMac-style)

    /// All root directories an area acts on, including dynamic volume trashes.
    static func cleanRoots(_ area: CleanArea) -> [URL] {
        area == .trashBins ? area.folderRoots + volumeTrashes() : area.folderRoots
    }

    static func volumeTrashes() -> [URL] {
        let uid = getuid()
        var out: [URL] = []
        for vol in Helpers.contents(URL(fileURLWithPath: "/Volumes")) {
            let t = vol.appendingPathComponent(".Trashes/\(uid)")
            if Helpers.isDir(t) { out.append(t) }
        }
        return out
    }

    /// Move (or, for the Trash, permanently delete) the top-level children of
    /// an area's root directories.
    static func folderClean(_ area: CleanArea, _ dryRun: Bool) -> CleanResult {
        var r = CleanResult(area: area)
        let children = cleanRoots(area)
            .filter { Helpers.isDir($0) }
            .flatMap { Helpers.contents($0) }
            .filter { $0.lastPathComponent != ".DS_Store" }
        if children.isEmpty { r.log("nothing to clean"); return r }
        r.removed = children.count
        let verb = area.permanentDelete ? "Delete" : "Trash"
        if dryRun {
            for c in children.prefix(30) {
                r.log("→ \(verb): \(c.lastPathComponent) (\(Helpers.humanSize(Helpers.pathSize(c)))) (dry-run)")
            }
            if children.count > 30 { r.log("… and \(children.count - 30) more") }
            r.log("total: \(children.count) items")
            return r
        }
        var done = 0
        for c in children {
            if area.permanentDelete {
                if (try? FileManager.default.removeItem(at: c)) != nil { done += 1 }
            } else if Helpers.moveToTrash(c) {
                done += 1
            }
        }
        r.log(area.permanentDelete
              ? "\(done) items permanently deleted"
              : "\(done) items moved to the Trash (recoverable)")
        return r
    }

    static func orphanAppData(_ dryRun: Bool) -> CleanResult {
        var r = CleanResult(area: .orphanAppData)
        let orphans = OrphanFinder.find(cap: 1000).filter { $0.confidence == .high }
        if orphans.isEmpty { r.log("no high-confidence leftovers to remove"); return r }
        r.removed = orphans.count
        if dryRun {
            for o in orphans.prefix(30) {
                r.log("→ Trash: \(o.ident) [\(o.location)] (\(Helpers.humanSize(o.size))) (dry-run)")
            }
            if orphans.count > 30 { r.log("… and \(orphans.count - 30) more") }
            r.log("total: \(orphans.count) leftovers would be moved to the Trash")
            return r
        }
        var moved = 0
        for o in orphans { if Helpers.moveToTrash(o.path) { moved += 1 } else { r.log("error on \(o.ident)") } }
        r.log("\(moved) leftovers moved to the Trash (recoverable)")
        return r
    }
}
