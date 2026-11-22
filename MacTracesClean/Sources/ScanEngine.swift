import Foundation

/// Shared Chromium-family browser locations (used by scan, clean and inventory).
enum BrowserPaths {
    static let chromiumBases: [(name: String, rel: String)] = [
        ("Chrome", "Library/Application Support/Google/Chrome"),
        ("Edge", "Library/Application Support/Microsoft Edge"),
        ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser"),
        ("Arc", "Library/Application Support/Arc/User Data"),
        ("Opera", "Library/Application Support/com.operasoftware.Opera"),
        ("Opera GX", "Library/Application Support/com.operasoftware.OperaGX"),
        ("Vivaldi", "Library/Application Support/Vivaldi"),
        ("Chromium", "Library/Application Support/Chromium"),
    ]

    /// History DB files for a Chromium-family root: the base dir itself (Opera)
    /// and every profile subdirectory (Chrome/Edge/Brave…).
    static func historyFiles(in root: URL) -> [(profile: String, url: URL)] {
        var out: [(String, URL)] = []
        let direct = root.appendingPathComponent("History")
        if Helpers.exists(direct) { out.append(("", direct)) }
        for profile in Helpers.contents(root) where Helpers.isDir(profile) {
            let h = profile.appendingPathComponent("History")
            if Helpers.exists(h) { out.append((profile.lastPathComponent, h)) }
        }
        return out
    }
}

enum ScanEngine {

    static func runAll(limit: Int, full: Bool) -> [ScanSection] {
        let l = max(1, limit)
        return [
            safariHistory(l),
            chromiumHistory(l),
            firefoxHistory(l),
            shellHistory(l),
            recentDocuments(l),
            downloads(l),
            credentials(l, full: full),
            wifi(l),
            orphanAppData(l),
            privacyArtifacts(l),
        ]
    }

    // MARK: Browsers

    static func safariHistory(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Safari history (visited sites)",
                            sensitivity: .high, icon: "safari",
                            note: "The most recent URLs visited in Safari.")
        let db = HOME.appendingPathComponent("Library/Safari/History.db")
        guard Helpers.exists(db) else {
            s.error = "Safari not in use or path not accessible."
            return s
        }
        s.cleanAction = .browser("safari")
        guard let copy = Helpers.copyLockedDB(db) else {
            s.error = "Can't read the DB (needs Full Disk Access?)."
            return s
        }
        defer { Helpers.cleanupTemp(copy) }
        let rows = SQLiteDB.query(copy, """
            SELECT i.url, v.title, v.visit_time
            FROM history_visits v JOIN history_items i ON i.id = v.history_item
            ORDER BY v.visit_time DESC LIMIT \(limit)
        """)
        for r in rows {
            let url = r[0].string ?? ""
            let title = r[1].string ?? ""
            let when = r[2].double.map { Helpers.appleTime($0) } ?? ""
            s.add(url, "\(title) \(when)".trimmingCharacters(in: .whitespaces))
        }
        if rows.isEmpty { s.error = "No data (or insufficient permissions)." }
        return s
    }

    static func chromiumHistory(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Chromium browser history (Chrome/Edge/Brave/Arc/Opera)",
                            sensitivity: .high, icon: "globe",
                            note: "Sites visited in Chromium-based browsers.")
        s.cleanAction = .browser("chromium")
        for base in BrowserPaths.chromiumBases {
            let root = HOME.appendingPathComponent(base.rel)
            guard Helpers.isDir(root) else { continue }
            for (profile, hist) in BrowserPaths.historyFiles(in: root) {
                guard let copy = Helpers.copyLockedDB(hist) else { continue }
                defer { Helpers.cleanupTemp(copy) }
                let rows = SQLiteDB.query(copy, """
                    SELECT url, title, last_visit_time
                    FROM urls ORDER BY last_visit_time DESC LIMIT \(limit)
                """)
                let tag = profile.isEmpty ? base.name : "\(base.name)/\(profile)"
                for r in rows {
                    let url = r[0].string ?? ""
                    let title = r[1].string ?? ""
                    let when = r[2].double.map { Helpers.webkitTime($0) } ?? ""
                    s.add(url, "[\(tag)] \(title) \(when)".trimmingCharacters(in: .whitespaces))
                }
            }
        }
        if s.items.isEmpty { s.error = "No Chromium browser found or data not readable." }
        return s
    }

    static func firefoxHistory(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Firefox history", sensitivity: .high,
                            icon: "flame", note: "Sites visited in Firefox.")
        s.cleanAction = .browser("firefox")
        let base = HOME.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard Helpers.isDir(base) else { s.error = "Firefox not installed."; return s }
        for profile in Helpers.contents(base) where Helpers.isDir(profile) {
            let places = profile.appendingPathComponent("places.sqlite")
            guard Helpers.exists(places), let copy = Helpers.copyLockedDB(places) else { continue }
            defer { Helpers.cleanupTemp(copy) }
            let rows = SQLiteDB.query(copy, """
                SELECT url, title, last_visit_date
                FROM moz_places WHERE last_visit_date IS NOT NULL
                ORDER BY last_visit_date DESC LIMIT \(limit)
            """)
            for r in rows {
                let url = r[0].string ?? ""
                let title = r[1].string ?? ""
                let when = r[2].double.map { Helpers.firefoxTime($0) } ?? ""
                s.add(url, "\(title) \(when)".trimmingCharacters(in: .whitespaces))
            }
        }
        if s.items.isEmpty && s.error.isEmpty { s.error = "No readable data." }
        return s
    }

    // MARK: Shell

    static func shellHistory(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Shell history (typed commands)",
                            sensitivity: .high, icon: "terminal",
                            note: "Commands may contain passwords, tokens or private paths.")
        s.cleanAction = .shell
        let files = [
            HOME.appendingPathComponent(".zsh_history"),
            HOME.appendingPathComponent(".bash_history"),
            HOME.appendingPathComponent(".local/share/fish/fish_history"),
        ]
        let secretRe = try! NSRegularExpression(
            pattern: "(password|passwd|token|secret|api[_-]?key|-p\\s|AWS_|BEARER|PRIVATE)",
            options: [.caseInsensitive])
        let tsRe = try! NSRegularExpression(pattern: "^: \\d+:\\d+;")
        for f in files {
            guard Helpers.exists(f), let data = try? Data(contentsOf: f) else { continue }
            let raw = String(decoding: data, as: UTF8.self)
            let lines = raw.components(separatedBy: .newlines)
            let flagged = lines.filter { matches(secretRe, $0) }
            s.add("\(f.lastPathComponent): \(lines.count) lines, \(flagged.count) potentially sensitive",
                  f.path)
            for ln in flagged.suffix(limit) {
                let clean = replace(tsRe, in: ln, with: "").trimmingCharacters(in: .whitespaces)
                s.add("⚠︎ " + String(clean.prefix(200)))
            }
        }
        if s.items.isEmpty { s.error = "No shell history file found." }
        return s
    }

    // MARK: Recent documents

    static func recentDocuments(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Recently opened documents", sensitivity: .medium,
                            icon: "doc.text", note: "Recent files recorded by apps and the system.")
        var count = 0
        let recentItems = HOME.appendingPathComponent("Library/Preferences/com.apple.recentitems.plist")
        if Helpers.exists(recentItems) {
            s.add("List present: \(recentItems.lastPathComponent)", recentItems.path)
            count += 1
        }
        let sfl = HOME.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        for f in Helpers.contents(sfl) where f.lastPathComponent.contains(".sfl") {
            if count >= limit { break }
            s.add("List present: \(f.lastPathComponent)", f.path)
            count += 1
        }
        let prefsDir = HOME.appendingPathComponent("Library/Preferences")
        var shown = 0
        for pref in Helpers.contents(prefsDir) where pref.pathExtension == "plist" {
            if shown >= limit { break }
            guard let dict = Helpers.readPlist(pref) else { continue }
            let rec = (dict["NSRecentDocumentRecords"] as? [Any]) ?? (dict["recentFiles"] as? [Any])
            if let rec = rec, !rec.isEmpty {
                s.add("\(pref.deletingPathExtension().lastPathComponent): \(rec.count) recent documents",
                      pref.path)
                shown += 1
            }
        }
        if s.items.isEmpty { s.error = "No readable recent-documents list." }
        return s
    }

    // MARK: Downloads

    static func downloads(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Recent downloads", sensitivity: .medium,
                            icon: "arrow.down.circle",
                            note: "Downloaded files (often reveal purchases, documents, attachments).")
        let d = HOME.appendingPathComponent("Downloads")
        guard Helpers.isDir(d) else { s.error = "Downloads folder not found."; return s }
        let files = Helpers.contents(d)
        guard !files.isEmpty || Helpers.exists(d) else {
            s.error = "Access denied to the Downloads folder."; return s
        }
        let sorted = files.sorted {
            mtime($0) > mtime($1)
        }
        for f in sorted.prefix(limit) {
            let when = Helpers.shortFormatter.string(from: Date(timeIntervalSince1970: mtime(f)))
            let size = Helpers.pathSize(f)
            s.add(f.lastPathComponent, "\(when)  \(size / 1024) KB")
        }
        s.add("Total items in the folder: \(files.count)")
        return s
    }

    // MARK: Credentials

    static func credentials(_ limit: Int, full: Bool) -> ScanSection {
        var s = ScanSection(title: "Plaintext credentials and keys", sensitivity: .high,
                            icon: "key", note: "Configuration files that typically contain secrets.")
        let targets: [(String, URL)] = [
            ("~/.aws/credentials", HOME.appendingPathComponent(".aws/credentials")),
            ("~/.ssh (private keys)", HOME.appendingPathComponent(".ssh")),
            ("~/.netrc", HOME.appendingPathComponent(".netrc")),
            ("~/.docker/config.json", HOME.appendingPathComponent(".docker/config.json")),
            ("~/.npmrc", HOME.appendingPathComponent(".npmrc")),
            ("~/.pypirc", HOME.appendingPathComponent(".pypirc")),
            ("~/.git-credentials", HOME.appendingPathComponent(".git-credentials")),
            ("~/.kube/config", HOME.appendingPathComponent(".kube/config")),
        ]
        let secretRe = try! NSRegularExpression(
            pattern: "(aws_secret_access_key|aws_access_key_id|password|_token|authToken|secret|api[_-]?key|BEGIN [A-Z ]*PRIVATE KEY)",
            options: [.caseInsensitive])
        for (label, path) in targets {
            guard Helpers.exists(path) else { continue }
            if Helpers.isDir(path) { // ~/.ssh
                for k in Helpers.contents(path)
                where k.lastPathComponent.hasPrefix("id_") && k.pathExtension != "pub" {
                    s.add("\(label): \(k.lastPathComponent)", "SSH private key present")
                }
                continue
            }
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                s.add("\(label): present (not readable)", path.path); continue
            }
            var hits = 0
            for line in text.components(separatedBy: .newlines) where matches(secretRe, line) {
                hits += 1
                if hits <= limit {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    let parts2 = line.split(separator: ":", maxSplits: 1).map(String.init)
                    let shown: String
                    if parts.count == 2 {
                        shown = "\(parts[0].trimmingCharacters(in: .whitespaces)) = \(Helpers.mask(parts[1], full: full))"
                    } else if parts2.count == 2 {
                        shown = "\(parts2[0].trimmingCharacters(in: .whitespaces)) = \(Helpers.mask(parts2[1], full: full))"
                    } else {
                        shown = Helpers.mask(line, full: full)
                    }
                    s.add("\(label): ⚠︎ \(shown)")
                }
            }
            if hits > 0 { s.add("\(label): \(hits) sensitive lines in total", path.path) }
        }
        // shallow .env scan in ~/<proj> and ~/<proj>/<sub>
        var envFound = 0
        for child in Helpers.contents(HOME) where Helpers.isDir(child) {
            if envFound >= limit { break }
            let env = child.appendingPathComponent(".env")
            if Helpers.exists(env) {
                s.add("Project .env file: \(env.path)", "potential environment secrets")
                envFound += 1
            }
            for sub in Helpers.contents(child) where Helpers.isDir(sub) {
                if envFound >= limit { break }
                let env2 = sub.appendingPathComponent(".env")
                if Helpers.exists(env2) {
                    s.add("Project .env file: \(env2.path)", "potential environment secrets")
                    envFound += 1
                }
            }
        }
        if s.items.isEmpty { s.error = "No common credential file found." }
        return s
    }

    // MARK: Wi-Fi

    static func wifi(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Known Wi-Fi networks", sensitivity: .medium,
                            icon: "wifi", note: "Saved networks reveal places you frequent (home, work, travel).")
        let out = Helpers.runCommand("/usr/sbin/networksetup",
                                     ["-listpreferredwirelessnetworks", "en0"])
        let lines = out.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Preferred") }
        for ln in lines.prefix(limit) { s.add(ln) }
        if !lines.isEmpty { s.add("Total preferred networks: \(lines.count)") }
        if s.items.isEmpty { s.error = "Network list unavailable (interface other than en0?)." }
        return s
    }

    // MARK: Privacy artifacts

    static func privacyArtifacts(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Assorted privacy artifacts", sensitivity: .low,
                            icon: "shippingbox", note: "Residual traces that often linger on the system.")
        let checks: [(String, String)] = [
            ("Quick Look thumbnails", "Library/Caches/com.apple.QuickLook.thumbnailcache"),
            ("Recent Spotlight cache", "Library/Metadata/CoreSpotlight"),
            ("Messages DB", "Library/Messages/chat.db"),
            ("Downloaded Mail", "Library/Mail"),
            ("Notes (NoteStore)", "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"),
            ("Calendar", "Library/Calendars"),
            ("Clipboard history (if any app)", "Library/Application Support"),
        ]
        for (label, rel) in checks {
            let p = HOME.appendingPathComponent(rel)
            if Helpers.exists(p) { s.add("\(label): present", p.path) }
        }
        return s
    }

    // MARK: Orphan app data

    static func orphanAppData(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Leftovers of uninstalled apps", sensitivity: .medium,
                            icon: "app.badge",
                            note: "Data in ~/Library that seems to belong to apps no longer installed. 'high' = almost certain (bundle id); 'low' = needs checking (name match).")
        let orphans = OrphanFinder.find(cap: limit * 4)
        if orphans.isEmpty { s.error = "No obvious leftovers found."; return s }
        let high = orphans.filter { $0.confidence == .high }.prefix(limit)
        let low = orphans.filter { $0.confidence == .low }.prefix(limit)
        for o in Array(high) + Array(low) {
            s.add("[\(o.confidence.rawValue)] \(o.ident)  (\(Helpers.humanSize(o.size)))",
                  "\(o.location): \(o.path.path)")
        }
        s.add("(largest shown; use Cleanup to remove the high-confidence ones)")
        return s
    }

    // MARK: Regex utilities

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        let r = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.firstMatch(in: s, options: [], range: r) != nil
    }

    static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        let r = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: t)
    }

    static func mtime(_ url: URL) -> TimeInterval {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}
