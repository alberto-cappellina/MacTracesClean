import SwiftUI
import AppKit

/// A clean action awaiting user confirmation (used by both section and space cards).
struct PendingClean: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let destructiveLabel: String
    let run: () -> Void
}

struct ScanView: View {
    @EnvironmentObject var model: AppModel
    @State private var inventoryArea: CleanArea?
    @State private var pending: PendingClean?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !model.sections.isEmpty {
                    statsRow
                }
                if model.hasPermissionIssues {
                    permissionBanner
                }
                if model.sections.isEmpty && !model.isScanning {
                    emptyState
                } else {
                    ForEach(model.sortedSections) { section in
                        SectionCard(section: section, pending: $pending)
                    }
                }

                spaceReclaimSection
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .navigationTitle("Privacy audit")
        .sheet(item: $inventoryArea) { area in
            InventorySheet(area: area)
        }
        .alert("Clean “\(pending?.title ?? "")” now?",
               isPresented: Binding(get: { pending != nil },
                                    set: { if !$0 { pending = nil } }),
               presenting: pending) { p in
            Button("Cancel", role: .cancel) { pending = nil }
            Button(p.destructiveLabel, role: .destructive) {
                p.run(); pending = nil
            }
        } message: { p in
            Text(p.message)
        }
    }

    private var spaceReclaimSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reclaimable space").font(.title3.weight(.bold))
                Spacer()
                if model.isCleaning { ProgressView().controlSize(.small) }
                let total = model.areaSizes.values.reduce(Int64(0), +)
                if total > 0 {
                    Text(Helpers.humanSize(total))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("CleanMyMac-style cleanup. Sizes are computed on the fly; files go to the Trash (the Trash itself is emptied permanently).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(CleanArea.spaceAreas) { area in
                CleanSpaceCard(area: area,
                               inventoryArea: $inventoryArea,
                               pending: $pending)
            }
        }
        .padding(.top, 6)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What is exposed on your Mac")
                    .font(.title2.weight(.bold))
                Text("Read-only scan. No data leaves the computer.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let d = model.lastScan {
                    Text("Last scan: \(d.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                Task { await model.scan() }
            } label: {
                HStack(spacing: 7) {
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(model.isScanning ? "Scanning…" : "Scan")
                }
                .frame(minWidth: 108)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isScanning)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatTile(value: "\(model.totalFindings)", label: "Items found")
            StatTile(value: "\(model.highCount)", label: "High-sensitivity categories",
                     tint: Sensitivity.high.color)
            StatTile(value: "\(model.sections.count)", label: "Categories analyzed",
                     tint: .secondary)
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some sections are empty due to missing permissions")
                    .font(.subheadline.weight(.semibold))
                Text("Add MacTracesClean under System Settings › Privacy & Security › Full Disk Access, then relaunch the app and try again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 46)).foregroundStyle(.secondary)
            Text("Press “Scan” to analyze your Mac")
                .font(.headline)
            Text("MacTracesClean lists histories, plaintext credentials, saved Wi-Fi networks and leftovers of uninstalled apps.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct SectionCard: View {
    let section: ScanSection
    @Binding var pending: PendingClean?
    @EnvironmentObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconBadge(system: section.icon, tint: section.sensitivity.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title).font(.headline)
                        if !section.note.isEmpty {
                            Text(section.note).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    SeverityPill(sensitivity: section.sensitivity)
                }

                if !section.error.isEmpty {
                    Label(section.error, systemImage: section.looksLikePermission ? "lock" : "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if section.items.isEmpty {
                    Text("No items.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack {
                            Text("\(section.items.count) items")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(section.items.prefix(200)) { item in
                                FindingRow(item: item)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                if let action = section.cleanAction {
                    cleanRow(action)
                }
            }
        }
    }

    @ViewBuilder private func cleanRow(_ action: ScanCleanAction) -> some View {
        HStack(spacing: 8) {
            if let msg = model.scanCleanMsg[action] {
                Label(msg, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                pending = PendingClean(
                    title: action.title,
                    message: action.confirmMessage,
                    destructiveLabel: "Clean") {
                        Task { await model.cleanScan(action) }
                    }
            } label: {
                Label("Clean now", systemImage: "trash")
            }
            .tint(.red)
            .controlSize(.small)
            .disabled(model.isCleaning)
        }
    }
}

struct CleanSpaceCard: View {
    let area: CleanArea
    @Binding var inventoryArea: CleanArea?
    @Binding var pending: PendingClean?
    @EnvironmentObject var model: AppModel
    @State private var size: Int64?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconBadge(system: area.icon, tint: .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(area.title).font(.headline)
                        Text(area.desc).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let s = size {
                        Text(Helpers.humanSize(s))
                            .font(.title3.weight(.semibold).monospacedDigit())
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }

                if let r = model.lastAreaResult[area], let m = r.messages.last {
                    Label(m, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                }

                HStack(spacing: 10) {
                    Button { inventoryArea = area } label: {
                        Label("Inventory", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        pending = PendingClean(
                            title: area.title,
                            message: area.confirmMessage,
                            destructiveLabel: area.permanentDelete ? "Delete" : "Clean") {
                                Task { await model.cleanSingle(area) }
                            }
                    } label: {
                        Label("Clean now", systemImage: "trash")
                    }
                    .tint(.red)
                    .disabled(model.isCleaning)
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .task(id: model.cleanGeneration) {
            size = await model.areaSize(for: area)
        }
    }
}

struct FindingRow: View {
    let item: Finding
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.detail)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            if !item.extra.isEmpty {
                Text(item.extra)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5).padding(.horizontal, 9)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
    }
}
