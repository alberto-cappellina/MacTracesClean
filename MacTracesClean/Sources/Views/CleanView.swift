import SwiftUI
import AppKit

struct CleanView: View {
    @EnvironmentObject var model: AppModel
    @State private var showApplyConfirm = false
    @State private var inventoryArea: CleanArea?
    @State private var pendingClean: CleanArea?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                safetyBanner

                ForEach(CleanArea.allCases) { area in
                    CleanAreaRow(area: area,
                                 inventoryArea: $inventoryArea,
                                 pendingClean: $pendingClean)
                }

                backupRow
                batchActionBar

                if !model.cleanResults.isEmpty {
                    resultsPanel
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .navigationTitle("Trace cleanup")
        .sheet(item: $inventoryArea) { area in
            InventorySheet(area: area)
        }
        .alert("Clean “\(pendingClean?.title ?? "")” now?",
               isPresented: Binding(get: { pendingClean != nil },
                                    set: { if !$0 { pendingClean = nil } }),
               presenting: pendingClean) { area in
            Button("Cancel", role: .cancel) { pendingClean = nil }
            Button("Clean", role: .destructive) {
                let a = area; pendingClean = nil
                Task { await model.cleanSingle(a) }
            }
        } message: { area in
            Text(area.confirmMessage)
        }
        .alert("Run cleanup for the enabled areas?", isPresented: $showApplyConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Run", role: .destructive) { Task { await model.clean(apply: true) } }
        } message: {
            Text("These operations modify or remove data. Files are moved to the Trash (recoverable) and, if enabled, a backup is created. Browser histories, however, are permanently deleted.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trace cleanup").font(.title2.weight(.bold))
            Text("Act on a single section with “Clean now”, or use the toggles for a batch cleanup. “Inventory” shows exactly which files would be touched.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var safetyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            Text("Safe by default: credentials are never touched and, where possible, files go to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var backupRow: some View {
        Card {
            Toggle(isOn: $model.backup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create a backup before modifying").font(.subheadline.weight(.medium))
                    Text("Copies the files to ~/MacTracesClean_backups before the real run.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: 12) {
            Text("Batch cleanup of the enabled areas:")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await model.clean(apply: false) }
            } label: {
                Label("Preview", systemImage: "eye")
            }
            .disabled(model.enabledAreas.isEmpty || model.isCleaning)

            Button {
                showApplyConfirm = true
            } label: {
                Label("Run all", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(model.enabledAreas.isEmpty || model.isCleaning)

            if model.isCleaning { ProgressView().controlSize(.small) }
            Spacer()
        }
    }

    private var resultsPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: model.lastCleanWasApply ? "checkmark.circle.fill" : "eye.circle.fill")
                        .foregroundStyle(model.lastCleanWasApply ? .green : .blue)
                    Text(model.lastCleanWasApply ? "Cleanup done" : "Preview (no changes)")
                        .font(.headline)
                }
                ForEach(model.cleanResults) { res in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(res.area.title).font(.subheadline.weight(.semibold))
                        ForEach(Array(res.messages.enumerated()), id: \.offset) { _, m in
                            Text("• \(m)").font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    Divider()
                }
                let total = model.cleanResults.reduce(0) { $0 + $1.removed }
                Text(model.lastCleanWasApply
                     ? "Total: \(total) items processed."
                     : "Dry-run: \(total) items would be removed.")
                    .font(.footnote.weight(.medium))
            }
        }
    }
}

struct CleanAreaRow: View {
    let area: CleanArea
    @Binding var inventoryArea: CleanArea?
    @Binding var pendingClean: CleanArea?
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconBadge(system: area.icon, tint: .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(area.title).font(.headline)
                        Text(area.desc).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: model.binding(for: area))
                        .toggleStyle(.switch).labelsHidden()
                        .help("Include in the batch cleanup")
                }

                options

                HStack(spacing: 10) {
                    Button {
                        inventoryArea = area
                    } label: {
                        Label("Inventory", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        pendingClean = area
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
    }

    @ViewBuilder private var options: some View {
        switch area {
        case .browserHistory:
            HStack(spacing: 16) {
                Toggle("Safari", isOn: model.targetBinding("safari"))
                Toggle("Chromium", isOn: model.targetBinding("chromium"))
                Toggle("Firefox", isOn: model.targetBinding("firefox"))
            }
            .toggleStyle(.checkbox).font(.caption)
        case .shellHistory:
            Picker("Mode", selection: $model.shellMode) {
                ForEach(ShellMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup).font(.caption)
        case .downloadsOld:
            HStack {
                Text("Older than").font(.caption)
                Stepper("\(Int(model.downloadsDays)) days", value: $model.downloadsDays,
                        in: 7...365, step: 7)
                    .font(.caption)
            }
        case .quicklookCache, .orphanAppData, .userCaches, .appLogs,
             .xcodeJunk, .devCaches, .iosBackups, .mailAttachments, .trashBins:
            EmptyView()
        }
    }
}

struct InventorySheet: View {
    let area: CleanArea
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [InventoryItem] = []
    @State private var loading = true

    private var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inventory — \(area.title)").font(.headline)
                    Text("Affected files, sorted by absolute path.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if loading {
                VStack { ProgressView("Scanning…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No files to show for this section.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    InventoryRow(item: item)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(items.count) items · \(Helpers.humanSize(totalSize))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Button {
                        pendingAndClean()
                    } label: {
                        Label("Clean this section", systemImage: "trash")
                    }
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(model.isCleaning)
                }
            }
            .padding(12)
        }
        .frame(width: 760, height: 540)
        .task {
            items = await model.inventory(for: area)
            loading = false
        }
    }

    private func pendingAndClean() {
        dismiss()
        Task { await model.cleanSingle(area) }
    }
}

struct InventoryRow: View {
    let item: InventoryItem
    var body: some View {
        HStack(spacing: 10) {
            Text(item.kind)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .frame(width: 118, alignment: .leading)
                .lineLimit(1)
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(item.path)
                .font(.system(.caption, design: .monospaced))
                .truncationMode(.middle)
                .lineLimit(1)
                .textSelection(.enabled)
                .help(item.path)
            Spacer(minLength: 8)
            Text(Helpers.humanSize(item.size))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
    }
}
