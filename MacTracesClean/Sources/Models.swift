import SwiftUI

// MARK: - Sensitivity

enum Sensitivity: String, Codable, Hashable {
    case high, medium, low

    var color: Color {
        switch self {
        case .high:   return Color(red: 0.90, green: 0.26, blue: 0.24)
        case .medium: return Color(red: 0.95, green: 0.60, blue: 0.14)
        case .low:    return Color(red: 0.92, green: 0.80, blue: 0.20)
        }
    }

    var label: String {
        switch self {
        case .high:   return "High"
        case .medium: return "Medium"
        case .low:    return "Low"
        }
    }

    var rank: Int {
        switch self {
        case .high:   return 0
        case .medium: return 1
        case .low:    return 2
        }
    }
}

// MARK: - Scan results

struct Finding: Identifiable, Hashable {
    let id = UUID()
    var detail: String
    var extra: String = ""
}

/// A targeted cleanup that a scan section can trigger directly.
enum ScanCleanAction: Hashable {
    case browser(String)   // target key: "safari" | "chromium" | "firefox"
    case shell

    var title: String {
        switch self {
        case .browser(let t): return "\(t.capitalized) history"
        case .shell:          return "shell history"
        }
    }
    var confirmMessage: String {
        switch self {
        case .browser: return "The history will be permanently deleted (close the browser first)."
        case .shell:   return "The shell history lines will be removed. A backup is created if enabled."
        }
    }
}

struct ScanSection: Identifiable {
    let id = UUID()
    var title: String
    var sensitivity: Sensitivity
    var icon: String
    var note: String = ""
    var items: [Finding] = []
    var error: String = ""
    var cleanAction: ScanCleanAction? = nil

    mutating func add(_ detail: String, _ extra: String = "") {
        items.append(Finding(detail: detail, extra: extra))
    }

    /// True when the error text hints at a Full Disk Access permission issue.
    var looksLikePermission: Bool {
        let e = error.lowercased()
        return e.contains("full disk") || e.contains("permission") || e.contains("denied")
            || e.contains("can't read") || e.contains("cannot read") || e.contains("not readable")
    }
}

// MARK: - Cleaning

enum CleanArea: String, CaseIterable, Identifiable, Hashable {
    case browserHistory
    case shellHistory
    case quicklookCache
    case downloadsOld
    case orphanAppData
    // CleanMyMac-style areas (directory-based)
    case userCaches
    case appLogs
    case xcodeJunk
    case devCaches
    case iosBackups
    case mailAttachments
    case trashBins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browserHistory: return "Browser history"
        case .shellHistory:   return "Shell history"
        case .quicklookCache: return "Quick Look cache"
        case .downloadsOld:   return "Old downloads"
        case .orphanAppData:  return "Leftovers of uninstalled apps"
        case .userCaches:     return "User caches"
        case .appLogs:        return "Application logs"
        case .xcodeJunk:      return "Developer leftovers (Xcode)"
        case .devCaches:      return "Developer caches (npm, Gradle, pip…)"
        case .iosBackups:     return "iOS backups and updates"
        case .mailAttachments: return "Mail attachments"
        case .trashBins:      return "Trash"
        }
    }

    var desc: String {
        switch self {
        case .browserHistory: return "Clears browsing history (requires the browser to be closed)."
        case .shellHistory:   return "Cleans ~/.zsh_history and ~/.bash_history."
        case .quicklookCache: return "Empties the Quick Look thumbnail cache (it rebuilds itself)."
        case .downloadsOld:   return "Moves downloads older than N days to the Trash (recoverable)."
        case .orphanAppData:  return "Moves leftovers of uninstalled apps to the Trash (high-confidence only)."
        case .userCaches:     return "Empties ~/Library/Caches: app caches (they rebuild themselves)."
        case .appLogs:        return "Removes application logs in ~/Library/Logs."
        case .xcodeJunk:      return "DerivedData, archives, Device Support and Xcode simulator caches."
        case .devCaches:      return "Package manager caches (~/.npm, ~/.gradle, ~/.cache, ~/.pub-cache, ~/.m2, ~/.cargo). They are rebuilt on the next build."
        case .iosBackups:     return "Saved iOS/iPadOS backups and software updates (often many GB)."
        case .mailAttachments: return "Attachments downloaded by Mail (~/Library/Containers/com.apple.mail…)."
        case .trashBins:      return "Empties the Trash, including per-volume trashes (permanent deletion)."
        }
    }

    var icon: String {
        switch self {
        case .browserHistory: return "safari"
        case .shellHistory:   return "terminal"
        case .quicklookCache: return "eye.trianglebadge.exclamationmark"
        case .downloadsOld:   return "arrow.down.circle"
        case .orphanAppData:  return "app.badge"
        case .userCaches:     return "internaldrive"
        case .appLogs:        return "list.bullet.rectangle.portrait"
        case .xcodeJunk:      return "hammer"
        case .devCaches:      return "shippingbox"
        case .iosBackups:     return "iphone"
        case .mailAttachments: return "envelope"
        case .trashBins:      return "trash"
        }
    }

    /// True for areas that permanently delete rather than move to Trash.
    var permanentDelete: Bool { self == .trashBins }

    /// Root directories whose top-level children this area acts on.
    /// Empty for the legacy areas, which have bespoke logic.
    var folderRoots: [URL] {
        func h(_ p: String) -> URL { HOME.appendingPathComponent(p) }
        switch self {
        case .userCaches:
            return [h("Library/Caches")]
        case .appLogs:
            return [h("Library/Logs")]
        case .xcodeJunk:
            return [h("Library/Developer/Xcode/DerivedData"),
                    h("Library/Developer/Xcode/Archives"),
                    h("Library/Developer/Xcode/iOS DeviceSupport"),
                    h("Library/Developer/Xcode/watchOS DeviceSupport"),
                    h("Library/Developer/Xcode/tvOS DeviceSupport"),
                    h("Library/Developer/CoreSimulator/Caches")]
        case .devCaches:
            return [h(".npm/_cacache"),
                    h(".yarn/cache"),
                    h(".gradle/caches"),
                    h(".m2/repository"),
                    h(".cargo/registry/cache"),
                    h(".pub-cache"),
                    h(".cache"),
                    h(".cocoapods/repos")]
        case .iosBackups:
            return [h("Library/Application Support/MobileSync/Backup"),
                    h("Library/iTunes/iPhone Software Updates")]
        case .mailAttachments:
            return [h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]
        case .trashBins:
            return [h(".Trash")]
        default:
            return []
        }
    }

    var isFolderArea: Bool { !folderRoots.isEmpty }

    /// Confirmation text shown before cleaning a single area.
    var confirmMessage: String {
        switch self {
        case .browserHistory:
            return "The history of the selected browsers will be permanently deleted (close the browsers first)."
        case .shellHistory:
            return "The shell history lines will be removed. A backup is created if enabled."
        case .trashBins:
            return "The contents of the Trash will be PERMANENTLY deleted and cannot be recovered."
        default:
            return "The items will be moved to the Trash (recoverable)."
        }
    }

    /// Space-reclaim areas shown on the Overview page, roughly largest first.
    static let spaceAreas: [CleanArea] = [
        .devCaches, .userCaches, .xcodeJunk, .iosBackups, .appLogs,
        .mailAttachments, .quicklookCache, .downloadsOld, .orphanAppData, .trashBins,
    ]
}

enum ShellMode: String, CaseIterable, Identifiable {
    case secretsOnly
    case all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .secretsOnly: return "Only lines with secrets"
        case .all:         return "The entire history"
        }
    }
}

/// Immutable snapshot passed to the off-main cleaning engine.
struct CleanConfigSnapshot {
    var enabled: Set<CleanArea>
    var browserTargets: Set<String>
    var shellMode: ShellMode
    var downloadsOlderThanDays: Int
    var backup: Bool
}

struct CleanResult: Identifiable {
    let id = UUID()
    var area: CleanArea
    var removed: Int = 0
    var messages: [String] = []
    mutating func log(_ m: String) { messages.append(m) }
}
