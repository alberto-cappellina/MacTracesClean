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
        .navigationTitle("Pulizia tracce")
        .sheet(item: $inventoryArea) { area in
            InventorySheet(area: area)
        }
        .alert("Pulire “\(pendingClean?.title ?? "")” adesso?",
               isPresented: Binding(get: { pendingClean != nil },
                                    set: { if !$0 { pendingClean = nil } }),
               presenting: pendingClean) { area in
            Button("Annulla", role: .cancel) { pendingClean = nil }
            Button("Pulisci", role: .destructive) {
                let a = area; pendingClean = nil
                Task { await model.cleanSingle(a) }
            }
        } message: { area in
            Text(area.confirmMessage)
        }
        .alert("Eseguire la pulizia delle aree attive?", isPresented: $showApplyConfirm) {
            Button("Annulla", role: .cancel) { }
            Button("Esegui", role: .destructive) { Task { await model.clean(apply: true) } }
        } message: {
            Text("Le operazioni modificano o rimuovono dati. I file vengono spostati nel Cestino (recuperabili) e, se attivo, viene creato un backup. Le cronologie dei browser vengono invece cancellate in modo definitivo.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pulizia tracce").font(.title2.weight(.bold))
            Text("Agisci su una singola sezione con “Pulisci adesso”, o usa i toggle per una pulizia in blocco. “Inventario” mostra esattamente quali file verrebbero toccati.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var safetyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            Text("Sicuro di default: le credenziali non vengono mai toccate e, dove possibile, i file finiscono nel Cestino.")
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
                    Text("Crea un backup prima di modificare").font(.subheadline.weight(.medium))
                    Text("Copia i file in ~/privacy_audit_backups prima dell'esecuzione reale.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: 12) {
            Text("Pulizia in blocco delle aree attivate:")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await model.clean(apply: false) }
            } label: {
                Label("Anteprima", systemImage: "eye")
            }
            .disabled(model.enabledAreas.isEmpty || model.isCleaning)

            Button {
                showApplyConfirm = true
            } label: {
                Label("Esegui tutte", systemImage: "trash")
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
                    Text(model.lastCleanWasApply ? "Pulizia eseguita" : "Anteprima (nessuna modifica)")
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
                     ? "Totale: \(total) elementi elaborati."
                     : "Dry-run: \(total) elementi verrebbero rimossi.")
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
                        .help("Includi nella pulizia in blocco")
                }

                options

                HStack(spacing: 10) {
                    Button {
                        inventoryArea = area
                    } label: {
                        Label("Inventario", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        pendingClean = area
                    } label: {
                        Label("Pulisci adesso", systemImage: "trash")
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
            Picker("Modalità", selection: $model.shellMode) {
                ForEach(ShellMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup).font(.caption)
        case .downloadsOld:
            HStack {
                Text("Più vecchi di").font(.caption)
                Stepper("\(Int(model.downloadsDays)) giorni", value: $model.downloadsDays,
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
                    Text("Inventario — \(area.title)").font(.headline)
                    Text("File interessati, ordinati per percorso assoluto.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Chiudi") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if loading {
                VStack { ProgressView("Analisi in corso…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Nessun file da mostrare per questa sezione.")
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
                Text("\(items.count) elementi · \(Helpers.humanSize(totalSize))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Button {
                        pendingAndClean()
                    } label: {
                        Label("Pulisci questa sezione", systemImage: "trash")
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
            .help("Mostra nel Finder")
        }
        .padding(.vertical, 2)
    }
}
