import SwiftUI

// MARK: - Sensitivity

enum Sensitivity: String, Codable, Hashable {
    case alta, media, bassa

    var color: Color {
        switch self {
        case .alta:  return Color(red: 0.90, green: 0.26, blue: 0.24)
        case .media: return Color(red: 0.95, green: 0.60, blue: 0.14)
        case .bassa: return Color(red: 0.92, green: 0.80, blue: 0.20)
        }
    }

    var label: String {
        switch self {
        case .alta:  return "Alta"
        case .media: return "Media"
        case .bassa: return "Bassa"
        }
    }

    var rank: Int {
        switch self {
        case .alta:  return 0
        case .media: return 1
        case .bassa: return 2
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
        case .browser(let t): return "cronologia \(t.capitalized)"
        case .shell:          return "cronologia shell"
        }
    }
    var confirmMessage: String {
        switch self {
        case .browser: return "La cronologia verrà cancellata in modo definitivo (chiudi prima il browser)."
        case .shell:   return "Le righe della cronologia shell verranno rimosse. Se attivo, viene creato un backup."
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
        return e.contains("full disk") || e.contains("permess") || e.contains("negato")
            || e.contains("leggere il db")
    }
}

// MARK: - Cleaning

enum CleanArea: String, CaseIterable, Identifiable, Hashable {
    case browserHistory
    case shellHistory
    case quicklookCache
    case downloadsOld
    case orphanAppData
    // Aree in stile CleanMyMac (basate su directory)
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
        case .browserHistory: return "Cronologia browser"
        case .shellHistory:   return "Cronologia shell"
        case .quicklookCache: return "Cache Quick Look"
        case .downloadsOld:   return "Download vecchi"
        case .orphanAppData:  return "Residui di app disinstallate"
        case .userCaches:     return "Cache utente"
        case .appLogs:        return "Log applicazioni"
        case .xcodeJunk:      return "Residui di sviluppo (Xcode)"
        case .devCaches:      return "Cache sviluppo (npm, Gradle, pip…)"
        case .iosBackups:     return "Backup iOS e aggiornamenti"
        case .mailAttachments: return "Allegati Mail"
        case .trashBins:      return "Cestino"
        }
    }

    var desc: String {
        switch self {
        case .browserHistory: return "Cancella la cronologia di navigazione (richiede il browser chiuso)."
        case .shellHistory:   return "Pulisce ~/.zsh_history e ~/.bash_history."
        case .quicklookCache: return "Svuota la cache delle anteprime Quick Look (si rigenera da sola)."
        case .downloadsOld:   return "Sposta nel Cestino i download più vecchi di N giorni (recuperabili)."
        case .orphanAppData:  return "Sposta nel Cestino i residui di app disinstallate (solo ad alta confidenza)."
        case .userCaches:     return "Svuota ~/Library/Caches: cache delle app (si rigenerano da sole)."
        case .appLogs:        return "Rimuove i log delle applicazioni in ~/Library/Logs."
        case .xcodeJunk:      return "DerivedData, archivi, Device Support e cache dei simulatori Xcode."
        case .devCaches:      return "Cache dei package manager (~/.npm, ~/.gradle, ~/.cache, ~/.pub-cache, ~/.m2, ~/.cargo). Si ricostruiscono alla build successiva."
        case .iosBackups:     return "Backup iOS/iPadOS e aggiornamenti software salvati (spesso molti GB)."
        case .mailAttachments: return "Allegati scaricati da Mail (~/Library/Containers/com.apple.mail…)."
        case .trashBins:      return "Svuota il Cestino, inclusi i cestini dei volumi (eliminazione definitiva)."
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
            return "La cronologia dei browser selezionati verrà cancellata in modo definitivo (chiudi prima i browser)."
        case .shellHistory:
            return "Le righe della cronologia shell verranno rimosse. Se attivo, viene creato un backup."
        case .trashBins:
            return "Il contenuto del Cestino verrà eliminato in modo DEFINITIVO e non sarà recuperabile."
        default:
            return "Gli elementi verranno spostati nel Cestino (recuperabili)."
        }
    }

    /// Space-reclaim areas shown on the Analisi page, roughly largest first.
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
        case .secretsOnly: return "Solo righe con segreti"
        case .all:         return "Tutta la cronologia"
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
