import SwiftUI

/// Reachable from Settings *and* from the Welcome screen (via a small
/// discreet link) — onboarding problems need to be capturable even before
/// the user can reach Settings normally.
struct DebugLogView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var levelFilter: LogLevel?

    private var filteredEntries: [LogEntry] {
        guard let levelFilter else { return store.entries }
        return store.entries.filter { $0.level == levelFilter }
    }

    var body: some View {
        NavigationStack {
            List(filteredEntries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.formatted)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(for: entry.level))
                }
            }
            .listStyle(.plain)
            .navigationTitle("Debug Log (\(store.entries.count))")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All") { levelFilter = nil }
                        Button("Errors only") { levelFilter = .error }
                        Button("Info & above") { levelFilter = .info }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: store.exportText.isEmpty ? "(no log entries yet)" : store.exportText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { store.clear() } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .overlay {
                if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        "No log entries yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Use the app for a bit, then come back here.")
                    )
                }
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .error: return .red
        }
    }
}

#Preview {
    DebugLogView()
}
