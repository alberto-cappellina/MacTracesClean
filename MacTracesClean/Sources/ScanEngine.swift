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
        var s = ScanSection(title: "Cronologia Safari (siti visitati)",
                            sensitivity: .alta, icon: "safari",
                            note: "Elenco degli ultimi URL visitati in Safari.")
        let db = HOME.appendingPathComponent("Library/Safari/History.db")
        guard Helpers.exists(db) else {
            s.error = "Safari non in uso o percorso non accessibile."
            return s
        }
        s.cleanAction = .browser("safari")
        guard let copy = Helpers.copyLockedDB(db) else {
            s.error = "Impossibile leggere il DB (serve Full Disk Access?)."
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
        if rows.isEmpty { s.error = "Nessun dato (o permessi insufficienti)." }
        return s
    }

    static func chromiumHistory(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Cronologia browser Chromium (Chrome/Edge/Brave/Arc/Opera)",
                            sensitivity: .alta, icon: "globe",
                            note: "Siti visitati nei browser basati su Chromium.")
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
        if s.items.isEmpty { s.error = "Nessun browser Chromium trovato o dati non leggibili." }
        return s
    }

    static func firefoxHistory(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Cronologia Firefox", sensitivity: .alta,
                            icon: "flame", note: "Siti visitati in Firefox.")
        s.cleanAction = .browser("firefox")
        let base = HOME.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard Helpers.isDir(base) else { s.error = "Firefox non installato."; return s }
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
        if s.items.isEmpty && s.error.isEmpty { s.error = "Nessun dato leggibile." }
        return s
    }

    // MARK: Shell

    static func shellHistory(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Cronologia della shell (comandi digitati)",
                            sensitivity: .alta, icon: "terminal",
                            note: "I comandi possono contenere password, token o percorsi privati.")
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
            s.add("\(f.lastPathComponent): \(lines.count) righe, \(flagged.count) potenzialmente sensibili",
                  f.path)
            for ln in flagged.suffix(limit) {
                let clean = replace(tsRe, in: ln, with: "").trimmingCharacters(in: .whitespaces)
                s.add("⚠︎ " + String(clean.prefix(200)))
            }
        }
        if s.items.isEmpty { s.error = "Nessun file di cronologia shell trovato." }
        return s
    }

    // MARK: Recent documents

    static func recentDocuments(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Documenti aperti di recente", sensitivity: .media,
                            icon: "doc.text", note: "File recenti registrati dalle app e dal sistema.")
        var count = 0
        let recentItems = HOME.appendingPathComponent("Library/Preferences/com.apple.recentitems.plist")
        if Helpers.exists(recentItems) {
            s.add("Elenco presente: \(recentItems.lastPathComponent)", recentItems.path)
            count += 1
        }
        let sfl = HOME.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        for f in Helpers.contents(sfl) where f.lastPathComponent.contains(".sfl") {
            if count >= limit { break }
            s.add("Elenco presente: \(f.lastPathComponent)", f.path)
            count += 1
        }
        let prefsDir = HOME.appendingPathComponent("Library/Preferences")
        var shown = 0
        for pref in Helpers.contents(prefsDir) where pref.pathExtension == "plist" {
            if shown >= limit { break }
            guard let dict = Helpers.readPlist(pref) else { continue }
            let rec = (dict["NSRecentDocumentRecords"] as? [Any]) ?? (dict["recentFiles"] as? [Any])
            if let rec = rec, !rec.isEmpty {
                s.add("\(pref.deletingPathExtension().lastPathComponent): \(rec.count) documenti recenti",
                      pref.path)
                shown += 1
            }
        }
        if s.items.isEmpty { s.error = "Nessuna lista di documenti recenti leggibile." }
        return s
    }

    // MARK: Downloads

    static func downloads(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Download recenti", sensitivity: .media,
                            icon: "arrow.down.circle",
                            note: "File scaricati (spesso rivelano acquisti, documenti, allegati).")
        let d = HOME.appendingPathComponent("Downloads")
        guard Helpers.isDir(d) else { s.error = "Cartella Downloads non trovata."; return s }
        let files = Helpers.contents(d)
        guard !files.isEmpty || Helpers.exists(d) else {
            s.error = "Accesso negato alla cartella Downloads."; return s
        }
        let sorted = files.sorted {
            mtime($0) > mtime($1)
        }
        for f in sorted.prefix(limit) {
            let when = Helpers.shortFormatter.string(from: Date(timeIntervalSince1970: mtime(f)))
            let size = Helpers.pathSize(f)
            s.add(f.lastPathComponent, "\(when)  \(size / 1024) KB")
        }
        s.add("Totale elementi nella cartella: \(files.count)")
        return s
    }

    // MARK: Credentials

    static func credentials(_ limit: Int, full: Bool) -> ScanSection {
        var s = ScanSection(title: "Credenziali e chiavi in chiaro", sensitivity: .alta,
                            icon: "key", note: "File di configurazione che tipicamente contengono segreti.")
        let targets: [(String, URL)] = [
            ("~/.aws/credentials", HOME.appendingPathComponent(".aws/credentials")),
            ("~/.ssh (chiavi private)", HOME.appendingPathComponent(".ssh")),
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
                    s.add("\(label): \(k.lastPathComponent)", "chiave privata SSH presente")
                }
                continue
            }
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                s.add("\(label): presente (non leggibile)", path.path); continue
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
            if hits > 0 { s.add("\(label): \(hits) righe sensibili totali", path.path) }
        }
        // shallow .env scan in ~/<proj> and ~/<proj>/<sub>
        var envFound = 0
        for child in Helpers.contents(HOME) where Helpers.isDir(child) {
            if envFound >= limit { break }
            let env = child.appendingPathComponent(".env")
            if Helpers.exists(env) {
                s.add("File .env di progetto: \(env.path)", "potenziali segreti d'ambiente")
                envFound += 1
            }
            for sub in Helpers.contents(child) where Helpers.isDir(sub) {
                if envFound >= limit { break }
                let env2 = sub.appendingPathComponent(".env")
                if Helpers.exists(env2) {
                    s.add("File .env di progetto: \(env2.path)", "potenziali segreti d'ambiente")
                    envFound += 1
                }
            }
        }
        if s.items.isEmpty { s.error = "Nessun file di credenziali comune trovato." }
        return s
    }

    // MARK: Wi-Fi

    static func wifi(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Reti Wi-Fi conosciute", sensitivity: .media,
                            icon: "wifi", note: "Le reti salvate rivelano luoghi frequentati (casa, lavoro, viaggi).")
        let out = Helpers.runCommand("/usr/sbin/networksetup",
                                     ["-listpreferredwirelessnetworks", "en0"])
        let lines = out.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Preferred") }
        for ln in lines.prefix(limit) { s.add(ln) }
        if !lines.isEmpty { s.add("Totale reti preferite: \(lines.count)") }
        if s.items.isEmpty { s.error = "Elenco reti non disponibile (interfaccia diversa da en0?)." }
        return s
    }

    // MARK: Privacy artifacts

    static func privacyArtifacts(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Vari artefatti di privacy", sensitivity: .bassa,
                            icon: "shippingbox", note: "Tracce residue che spesso restano sul sistema.")
        let checks: [(String, String)] = [
            ("Quick Look thumbnails", "Library/Caches/com.apple.QuickLook.thumbnailcache"),
            ("Cache Spotlight recenti", "Library/Metadata/CoreSpotlight"),
            ("Messaggi (Messages) DB", "Library/Messages/chat.db"),
            ("Mail scaricata", "Library/Mail"),
            ("Note (NoteStore)", "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"),
            ("Calendario", "Library/Calendars"),
            ("Appunti/Clipboard history (se app)", "Library/Application Support"),
        ]
        for (label, rel) in checks {
            let p = HOME.appendingPathComponent(rel)
            if Helpers.exists(p) { s.add("\(label): presente", p.path) }
        }
        return s
    }

    // MARK: Orphan app data

    static func orphanAppData(_ limit: Int) -> ScanSection {
        var s = ScanSection(title: "Residui di app disinstallate", sensitivity: .media,
                            icon: "app.badge",
                            note: "Dati in ~/Library che sembrano appartenere ad app non più installate. 'alta' = quasi certo (bundle id); 'bassa' = da verificare (match per nome).")
        let orphans = OrphanFinder.find(cap: limit * 4)
        if orphans.isEmpty { s.error = "Nessun residuo evidente trovato."; return s }
        let high = orphans.filter { $0.confidence == .alta }.prefix(limit)
        let low = orphans.filter { $0.confidence == .bassa }.prefix(limit)
        for o in Array(high) + Array(low) {
            s.add("[\(o.confidence.rawValue)] \(o.ident)  (\(Helpers.humanSize(o.size)))",
                  "\(o.location): \(o.path.path)")
        }
        s.add("(mostrati i più grandi; usa la Pulizia per rimuovere quelli ad alta confidenza)")
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
