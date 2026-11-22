import Foundation
import SwiftUI
import application

struct NativePlaybackHistoryPage: View {
    let catalog: IosNativeCatalog
    let showPending: Bool

    @State private var handle: NativeScreenHandle<IosNativePlaybackHistory>?
    @State private var state: IosHistoryState?
    @State private var deletion: HistoryDeletion?

    var body: some View {
        List {
            if let state {
                if showPending {
                    pendingRows(state.pending)
                } else {
                    historyRows(state.entries)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(showPending ? LocalizedStringKey("History Sync Status") : LocalizedStringKey("Playback History"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !showPending {
                    NavigationLink(value: NativeRoute.historySync) {
                        Label("History Sync Status", systemImage: "arrow.up.arrow.down.circle")
                    }
                }
                Button("Sync Now", systemImage: "arrow.trianglehead.clockwise") { handle?.value.sync() }
                    .disabled(state == nil || state?.syncStatus == .syncing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if state?.syncStatus == .syncing {
                ProgressView("Syncing…")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .confirmationDialog(
            deletion?.title ?? "Delete History Entry?",
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            presenting: deletion
        ) { item in
            Button(item.actionTitle, role: .destructive) {
                switch item {
                case .history(let id): handle?.value.delete(episodeId: id)
                case .pending(let key): handle?.value.discardPending(key: key)
                }
            }
        }
        .alert(
            state?.syncStatus == .failed ? LocalizedStringKey("Sync Failed") : LocalizedStringKey("Sync Finished"),
            isPresented: Binding(
                get: { state?.syncStatus == .finished || state?.syncStatus == .failed },
                set: { if !$0 { handle?.value.dismissSyncStatus() } }
            )
        ) {
            Button("OK", role: .cancel) { handle?.value.dismissSyncStatus() }
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openPlaybackHistory()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }

    @ViewBuilder
    private func historyRows(_ rows: [IosHistoryEntry]) -> some View {
        if rows.isEmpty {
            ContentUnavailableView("No Playback History", systemImage: "clock")
        }
        ForEach(rows, id: \.episodeId) { row in
            Group {
                if row.subjectId > 0, row.episodeId > 0 {
                    NavigationLink(value: NativeRoute.episode(subjectId: row.subjectId, episodeId: row.episodeId)) {
                        historyRow(row)
                    }
                } else {
                    historyRow(row)
                }
            }
            .swipeActions(allowsFullSwipe: false) {
                Button("Delete", role: .destructive) { deletion = .history(row.episodeId) }
            }
        }
    }

    private func historyRow(_ row: IosHistoryEntry) -> some View {
        HStack(spacing: 12) {
            NativeActivityArtwork(url: row.artwork, symbol: "play.rectangle")
                .frame(width: 48, height: 68)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                historyName(row.name, episodeId: row.episodeId).font(.headline)
                if let episode = row.episode ?? row.episodeNumber, !episode.isEmpty {
                    Text(episode).font(.subheadline).foregroundStyle(.secondary)
                }
                if row.durationMillis > 0 {
                    ProgressView(value: min(1, max(0, Double(row.positionMillis) / Double(row.durationMillis))))
                }
                Text(nativeDate(row.updatedAtMillis), format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func pendingRows(_ rows: [IosHistoryPendingEntry]) -> some View {
        if rows.isEmpty {
            ContentUnavailableView("No Pending Changes", systemImage: "checkmark.circle")
        }
        ForEach(rows, id: \.key) { row in
            VStack(alignment: .leading, spacing: 6) {
                historyName(row.name, episodeId: row.episodeId).font(.headline)
                if let episode = row.episode {
                    Text(episode).font(.subheadline)
                }
                ForEach(row.actions, id: \.self) { action in
                    Text(actionName(action)).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(nativeDate(row.updatedAtMillis), format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .swipeActions(allowsFullSwipe: false) {
                Button("Discard Change", role: .destructive) { deletion = .pending(row.key) }
            }
        }
    }

    private func historyName(_ name: String?, episodeId: Int32) -> Text {
        if let name, !name.isEmpty { return Text(name) }
        return Text("Episode \(Int(episodeId))")
    }

    private func actionName(_ action: IosPendingHistoryAction) -> LocalizedStringKey {
        switch action {
        case .saveProgress: "Save Playback Progress"
        case .deleteProgress: "Delete Playback Progress"
        case .markWatched: "Mark as Watched"
        default: "Mark as Unwatched"
        }
    }
}

private enum HistoryDeletion {
    case history(Int32)
    case pending(String)

    var title: LocalizedStringKey {
        switch self {
        case .history: "Delete History Entry?"
        case .pending: "Discard Pending Changes?"
        }
    }

    var actionTitle: LocalizedStringKey {
        switch self {
        case .history: "Delete"
        case .pending: "Discard Change"
        }
    }
}
