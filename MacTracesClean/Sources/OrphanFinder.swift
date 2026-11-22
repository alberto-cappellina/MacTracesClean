import Foundation

enum Confidence: String {
    case high
    case low
}

struct Orphan {
    var path: URL
    var ident: String
    var location: String
    var confidence: Confidence
    var size: Int64 = 0
}

enum OrphanFinder {

    private static let bundleIdRe = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+){2,}$")

    private static let systemSkip: Set<String> = [
        "crashreporter", "mobilesync", "syncservices", "addressbook", "knowledge",
        "icdd", "clouddocs", "apple", "com.apple", "fontcollections", "metadata",
        "caches", "logs", "preferences", "containers", "coreservices",
    ]

    static func isBundleId(_ name: String) -> Bool {
        let r = NSRange(name.startIndex..<name.endIndex, in: name)
        guard bundleIdRe.firstMatch(in: name, options: [], range: r) != nil else { return false }
        let low = name.lowercased()
        return !(low.hasPrefix("com.apple") || low.hasPrefix("group.com.apple"))
    }

    static func bundleInstalled(_ ident: String, _ ids: Set<String>) -> Bool {
        let low = ident.lowercased()
        if ids.contains(low) { return true }
        return ids.contains { low.hasPrefix($0 + ".") || $0.hasPrefix(low + ".") }
    }

    static func nameKnown(_ name: String, _ names: Set<String>) -> Bool {
        let low = name.lowercased()
        if systemSkip.contains(low) || low.hasPrefix(".") || low.hasPrefix("com.apple") { return true }
        if names.contains(low) { return true }
        if low.count >= 3 { return names.contains { $0.contains(low) } }
        return false
    }

    /// Collect bundle ids and readable names of every installed app.
    static func installedIdentity() -> (ids: Set<String>, names: Set<String>) {
        var ids = Set<String>()
        var names = Set<String>()
        var appPaths: [String] = []
        let fm = FileManager.default

        let roots = ["/Applications",
                     HOME.appendingPathComponent("Applications").path,
                     "/System/Applications"]
        for root in roots {
            guard fm.fileExists(atPath: root) else { continue }
            // Walk manually, not descending into .app bundles.
            collectApps(in: URL(fileURLWithPath: root), into: &appPaths)
        }

        // Spotlight: find apps anywhere.
        let out = Helpers.runCommand("/usr/bin/mdfind",
            ["kMDItemContentTypeTree == 'com.apple.application-bundle'c"])
        appPaths += out.components(separatedBy: .newlines).filter { $0.hasSuffix(".app") }

        var seen = Set<String>()
        for app in appPaths where seen.insert(app).inserted {
            if seen.count > 3000 { break }
            let url = URL(fileURLWithPath: app)
            names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
            guard let d = Helpers.readPlist(url.appendingPathComponent("Contents/Info.plist")) else { continue }
            if let bid = d["CFBundleIdentifier"] as? String { ids.insert(bid.lowercased()) }
            for k in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let v = d[k] as? String { names.insert(v.lowercased()) }
            }
        }
        return (ids, names)
    }

    private static func collectApps(in root: URL, into paths: inout [String]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for item in items {
            if item.pathExtension == "app" {
                paths.append(item.path)
            } else if Helpers.isDir(item) {
                collectApps(in: item, into: &paths)
            }
        }
    }

    static func find(cap: Int = 300) -> [Orphan] {
        let (ids, names) = installedIdentity()
        var results: [Orphan] = []

        // Locations named with a bundle id (high precision).
        let bundleLocs: [(String, URL)] = [
            ("Containers", HOME.appendingPathComponent("Library/Containers")),
            ("Saved Application State", HOME.appendingPathComponent("Library/Saved Application State")),
            ("HTTPStorages", HOME.appendingPathComponent("Library/HTTPStorages")),
            ("WebKit", HOME.appendingPathComponent("Library/WebKit")),
        ]
        for (loc, base) in bundleLocs {
            guard Helpers.isDir(base) else { continue }
            for entry in Helpers.contents(base) {
                let ident = entry.lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
                guard isBundleId(ident), !bundleInstalled(ident, ids) else { continue }
                results.append(Orphan(path: entry, ident: ident, location: loc, confidence: .high))
            }
        }

        // Preferences: <bundleid>.plist
        let prefs = HOME.appendingPathComponent("Library/Preferences")
        if Helpers.isDir(prefs) {
            for entry in Helpers.contents(prefs) where entry.pathExtension == "plist" {
                let ident = entry.deletingPathExtension().lastPathComponent
                guard isBundleId(ident), !bundleInstalled(ident, ids) else { continue }
                results.append(Orphan(path: entry, ident: ident, location: "Preferences", confidence: .high))
            }
        }

        // Mixed locations: may use a bundle id or a readable name.
        for loc in ["Application Support", "Caches", "Logs"] {
            let base = HOME.appendingPathComponent("Library").appendingPathComponent(loc)
            guard Helpers.isDir(base) else { continue }
            for entry in Helpers.contents(base) {
                let name = entry.lastPathComponent
                if name.hasPrefix(".") { continue }
                let conf: Confidence
                if isBundleId(name) {
                    if bundleInstalled(name, ids) { continue }
                    conf = .high
                } else {
                    if nameKnown(name, names) { continue }
                    conf = .low
                }
                results.append(Orphan(path: entry, ident: name, location: loc, confidence: conf))
            }
        }

        for i in results.indices { results[i].size = Helpers.pathSize(results[i].path) }
        results.sort { a, b in
            if (a.confidence == .high) != (b.confidence == .high) {
                return a.confidence == .high
            }
            return a.size > b.size
        }
        return Array(results.prefix(cap))
    }
}
