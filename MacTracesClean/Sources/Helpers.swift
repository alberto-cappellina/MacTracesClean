import Foundation

let HOME = FileManager.default.homeDirectoryForCurrentUser

enum Helpers {

    // MARK: Time conversions

    /// Apple Cocoa timestamp (seconds since 2001-01-01).
    static func appleTime(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let base = Date(timeIntervalSinceReferenceDate: ts) // reference date == 2001-01-01
        return shortFormatter.string(from: base)
    }

    /// WebKit / Chrome timestamp (microseconds since 1601-01-01).
    static func webkitTime(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let seconds = ts / 1_000_000 - 11_644_473_600
        guard seconds > 0 else { return "" }
        return shortFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// Firefox timestamp (microseconds since 1970).
    static func firefoxTime(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        return shortFormatter.string(from: Date(timeIntervalSince1970: ts / 1_000_000))
    }

    static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    // MARK: Secret masking

    static func mask(_ value: String, full: Bool) -> String {
        if full { return value }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "" }
        if v.count <= 8 { return String(v.first!) + "…" }
        let start = v.prefix(4)
        let end = v.suffix(4)
        return "\(start)…\(end) (\(v.count) characters)"
    }

    // MARK: Locked DB copy

    /// Copy a (possibly locked) SQLite DB plus its -wal/-shm sidecars to a temp
    /// location so it can be read without disturbing the owning app.
    static func copyLockedDB(_ dbPath: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath.path) else { return nil }
        let tmpDir = fm.temporaryDirectory
        let tmp = tmpDir.appendingPathComponent("pa_\(getpid())_\(dbPath.lastPathComponent)")
        do {
            if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
            try fm.copyItem(at: dbPath, to: tmp)
            for suffix in ["-wal", "-shm"] {
                let side = dbPath.deletingLastPathComponent()
                    .appendingPathComponent(dbPath.lastPathComponent + suffix)
                if fm.fileExists(atPath: side.path) {
                    let sideTmp = tmp.deletingLastPathComponent()
                        .appendingPathComponent(tmp.lastPathComponent + suffix)
                    try? fm.removeItem(at: sideTmp)
                    try? fm.copyItem(at: side, to: sideTmp)
                }
            }
            return tmp
        } catch {
            return nil
        }
    }

    static func cleanupTemp(_ tmp: URL?) {
        guard let tmp = tmp else { return }
        let fm = FileManager.default
        for p in [tmp,
                  tmp.deletingLastPathComponent().appendingPathComponent(tmp.lastPathComponent + "-wal"),
                  tmp.deletingLastPathComponent().appendingPathComponent(tmp.lastPathComponent + "-shm")] {
            try? fm.removeItem(at: p)
        }
    }

    // MARK: Filesystem

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func isDir(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func contents(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants])) ?? []
    }

    /// Recursive size in bytes of a file or directory (best effort).
    static func pathSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                if let v = try? f.resourceValues(forKeys: [.fileSizeKey]),
                   let s = v.fileSize {
                    total += Int64(s)
                }
            }
        }
        return total
    }

    static func humanSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    // MARK: Plist

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return obj as? [String: Any]
    }

    // MARK: Shell command

    @discardableResult
    static func runCommand(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Backup & Trash

    static func backupFile(_ path: URL, into root: URL?) {
        guard let root = root, exists(path) else { return }
        let fm = FileManager.default
        let dest: URL
        let homePath = HOME.path
        if path.path.hasPrefix(homePath) {
            let rel = String(path.path.dropFirst(homePath.count).drop(while: { $0 == "/" }))
            dest = root.appendingPathComponent(rel)
        } else {
            dest = root.appendingPathComponent(path.lastPathComponent)
        }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.copyItem(at: path, to: dest)
    }

    @discardableResult
    static func moveToTrash(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }
}
