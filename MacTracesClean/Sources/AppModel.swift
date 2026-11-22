import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    // Scan
    @Published var sections: [ScanSection] = []
    @Published var isScanning = false
    @Published var lastScan: Date?
    @Published var limit = 10
    @Published var revealSecrets = false

    // Clean settings (persisted in UserDefaults)
    @Published var enabledAreas: Set<CleanArea> = [] { didSet { save() } }
    @Published var browserTargets: Set<String> = ["safari", "chromium", "firefox"] { didSet { save() } }
    @Published var shellMode: ShellMode = .secretsOnly { didSet { save() } }
    @Published var downloadsDays: Double = 90 { didSet { save() } }
    @Published var backup = true { didSet { save() } }

    private var loaded = false

    init() { load() }

    // Clean results
    @Published var cleanResults: [CleanResult] = []
    @Published var isCleaning = false
    @Published var lastCleanWasApply = false

    // Per-area reclaimable size (bytes), cached; bumped generation invalidates cards
    @Published var areaSizes: [CleanArea: Int64] = [:]
    @Published var lastAreaResult: [CleanArea: CleanResult] = [:]
    @Published var scanCleanMsg: [ScanCleanAction: String] = [:]
    @Published var cleanGeneration = 0

    var highCount: Int {
        sections.filter { $0.sensitivity == .alta && !$0.items.isEmpty }.count
    }
    var totalFindings: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }
    var hasPermissionIssues: Bool {
        sections.contains { $0.looksLikePermission }
    }

    /// Sections ordered by sensitivity (alta → bassa), stable within a level.
    var sortedSections: [ScanSection] {
        sections.enumerated().sorted {
            $0.element.sensitivity.rank != $1.element.sensitivity.rank
                ? $0.element.sensitivity.rank < $1.element.sensitivity.rank
                : $0.offset < $1.offset
        }.map { $0.element }
    }

    // MARK: Persistence

    private func load() {
        let d = UserDefaults.standard
        if let areas = d.array(forKey: "enabledAreas") as? [String] {
            enabledAreas = Set(areas.compactMap { CleanArea(rawValue: $0) })
        }
        if let t = d.array(forKey: "browserTargets") as? [String] {
            browserTargets = Set(t)
        }
        if let m = d.string(forKey: "shellMode"), let mode = ShellMode(rawValue: m) {
            shellMode = mode
        }
        if d.object(forKey: "downloadsDays") != nil {
            downloadsDays = max(7, d.double(forKey: "downloadsDays"))
        }
        if d.object(forKey: "backup") != nil {
            backup = d.bool(forKey: "backup")
        }
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        let d = UserDefaults.standard
        d.set(enabledAreas.map { $0.rawValue }, forKey: "enabledAreas")
        d.set(Array(browserTargets), forKey: "browserTargets")
        d.set(shellMode.rawValue, forKey: "shellMode")
        d.set(downloadsDays, forKey: "downloadsDays")
        d.set(backup, forKey: "backup")
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let l = limit
        let full = revealSecrets
        let result = await Task.detached(priority: .userInitiated) {
            ScanEngine.runAll(limit: l, full: full)
        }.value
        sections = result
        lastScan = Date()
        isScanning = false
    }

    func snapshot() -> CleanConfigSnapshot {
        CleanConfigSnapshot(
            enabled: enabledAreas,
            browserTargets: browserTargets,
            shellMode: shellMode,
            downloadsOlderThanDays: Int(downloadsDays),
            backup: backup)
    }

    /// Clean a single area immediately (apply). Result shown in the results panel.
    func cleanSingle(_ area: CleanArea) async {
        guard !isCleaning else { return }
        isCleaning = true
        lastCleanWasApply = true
        var snap = snapshot()
        snap.enabled = [area]
        let res = await Task.detached(priority: .userInitiated) {
            CleanEngine.run(snap, apply: true)
        }.value
        cleanResults = res
        if let r = res.first { lastAreaResult[area] = r }
        areaSizes[area] = nil          // force size recompute for this area
        cleanGeneration += 1
        isCleaning = false
    }

    /// Clean a single source straight from a scan section (e.g. just Safari).
    func cleanScan(_ action: ScanCleanAction) async {
        guard !isCleaning else { return }
        isCleaning = true
        lastCleanWasApply = true
        var snap = snapshot()
        switch action {
        case .browser(let target):
            snap.enabled = [.browserHistory]
            snap.browserTargets = [target]
        case .shell:
            snap.enabled = [.shellHistory]
        }
        let res = await Task.detached(priority: .userInitiated) {
            CleanEngine.run(snap, apply: true)
        }.value
        cleanResults = res
        scanCleanMsg[action] = res.first?.messages.last
        isCleaning = false
    }

    /// Build the file inventory for an area (absolute paths, sorted).
    func inventory(for area: CleanArea) async -> [InventoryItem] {
        let snap = snapshot()
        return await Task.detached(priority: .userInitiated) {
            InventoryEngine.items(for: area, snap)
        }.value
    }

    /// Reclaimable size of an area (bytes), computed off-main and cached.
    func areaSize(for area: CleanArea) async -> Int64 {
        if let s = areaSizes[area] { return s }
        let snap = snapshot()
        let size = await Task.detached(priority: .utility) {
            InventoryEngine.items(for: area, snap).reduce(Int64(0)) { $0 + $1.size }
        }.value
        areaSizes[area] = size
        return size
    }

    func clean(apply: Bool) async {
        guard !isCleaning else { return }
        isCleaning = true
        lastCleanWasApply = apply
        let snap = snapshot()
        let res = await Task.detached(priority: .userInitiated) {
            CleanEngine.run(snap, apply: apply)
        }.value
        cleanResults = res
        isCleaning = false
    }

    func toggle(_ area: CleanArea, _ on: Bool) {
        if on { enabledAreas.insert(area) } else { enabledAreas.remove(area) }
    }
    func binding(for area: CleanArea) -> Binding<Bool> {
        Binding(get: { self.enabledAreas.contains(area) },
                set: { self.toggle(area, $0) })
    }
    func targetBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.browserTargets.contains(key) },
                set: { on in if on { self.browserTargets.insert(key) } else { self.browserTargets.remove(key) } })
    }
}
