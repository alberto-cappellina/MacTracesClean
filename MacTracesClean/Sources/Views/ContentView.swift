import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case overview
    case clean
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("MacTracesClean") {
                    Label("Analisi privacy", systemImage: "magnifyingglass")
                        .badge(model.totalFindings)
                        .tag(SidebarItem.overview)
                    Label("Pulizia tracce", systemImage: "sparkles")
                        .badge(model.enabledAreas.isEmpty ? 0 : model.enabledAreas.count)
                        .tag(SidebarItem.clean)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                PermissionFooter()
            }
        } detail: {
            switch selection ?? .overview {
            case .overview: ScanView()
            case .clean:    CleanView()
            }
        }
    }
}

struct PermissionFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label("Full Disk Access", systemImage: "lock.shield")
                .font(.caption.weight(.semibold))
            Text("Alcune sezioni (Safari, Mail, Messaggi) richiedono il permesso.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Apri Impostazioni…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(10)
    }
}
