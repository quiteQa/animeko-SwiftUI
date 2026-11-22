import SwiftUI
import application

struct NativeBangumiMergePage: View {
    let catalog: IosNativeCatalog

    @State private var handle: NativeScreenHandle<IosNativeBangumiMerge>?
    @State private var state: IosBangumiMergeState?
    @State private var confirmRemoval = false

    var body: some View {
        List {
            if let state, state.status == .ready {
                if state.syncing {
                    ProgressView("Bangumi Sync in Progress")
                } else if state.groups.isEmpty {
                    Label("Collections Are in Sync", systemImage: "checkmark.circle")
                }
                if state.conflictCount > 0 {
                    Section {
                        ProgressView(value: Double(state.selectedCount), total: Double(state.conflictCount)) {
                            Text("\(Int(state.selectedCount)) of \(Int(state.conflictCount)) Resolved")
                        }
                    }
                }
                ForEach(state.groups, id: \.id) { group in
                    Section(group.title) {
                        ForEach(group.conflicts, id: \.id) { conflict in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(fieldTitle(conflict.field)).font(.headline)
                                option(conflict, side: .animeko, value: conflict.animeko)
                                option(conflict, side: .bangumi, value: conflict.bangumi)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if state.changeCount > 0 {
                    Section("Automatically Merged") {
                        ForEach(state.changes, id: \.key) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.title).font(.headline)
                                Text(fieldTitle(change.field)).font(.caption).foregroundStyle(.secondary)
                                Text(sideTitle(change.side)).font(.subheadline)
                                if let value = change.value {
                                    valueDetails(value, field: change.field)
                                }
                                if !change.watched.isEmpty {
                                    LabeledContent("Watched", value: change.watched.joined(separator: ", "))
                                }
                                if !change.unwatched.isEmpty {
                                    LabeledContent("Unwatched", value: change.unwatched.joined(separator: ", "))
                                }
                            }
                        }
                        if state.changeCount > Int32(state.changes.count) {
                            Text("Showing \(state.changes.count) of \(Int(state.changeCount)) Changes")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                NativeActivityFeedback(
                    status: state?.status,
                    emptyTitle: "Collections Are in Sync",
                    retry: { handle?.value.retry() }
                )
            }
        }
        .navigationTitle("Merge Bangumi Collections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let state, state.conflictCount > 0 {
                Menu("Choose for All Conflicts", systemImage: "ellipsis") {
                    Button("Use Newer Values") { handle?.value.selectNewer() }
                    Button("Use Animeko Values") { handle?.value.selectAll(side: .animeko) }
                    Button("Use Bangumi Values") { handle?.value.selectAll(side: .bangumi) }
                }
                .disabled(state.applying || state.syncing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let state, state.conflictCount > 0 {
                Button("Apply Merge") {
                    if removesCollection(state.groups) {
                        confirmRemoval = true
                    } else {
                        handle?.value.applyChoices()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!state.canApply)
                .padding()
            }
        }
        .confirmationDialog("Apply Merge and Remove Collections?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Apply Merge", role: .destructive) { handle?.value.applyChoices() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(outcomeTitle, isPresented: Binding(
            get: { (state?.outcome ?? IosMergeOutcome.none) != IosMergeOutcome.none },
            set: { if !$0 { handle?.value.dismissOutcome() } }
        )) {
            Button("OK", role: .cancel) { handle?.value.dismissOutcome() }
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openBangumiMerge()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }

    private var outcomeTitle: LocalizedStringKey {
        switch state?.outcome {
        case .applied: "Merge Complete"
        case .remaining: "Some Conflicts Remain"
        case .syncing: "Bangumi Sync in Progress"
        default: "Couldn’t Apply Merge"
        }
    }

    private func removesCollection(_ groups: [IosMergeGroup]) -> Bool {
        groups.contains { group in
            group.conflicts.contains { conflict in
                (conflict.selected == .animeko && conflict.animeko.removesCollection) ||
                    (conflict.selected == .bangumi && conflict.bangumi.removesCollection)
            }
        }
    }

    private func option(_ conflict: IosMergeConflict, side: IosMergeSide, value: IosMergeValue) -> some View {
        Button {
            handle?.value.select(id: conflict.id, side: side)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sideTitle(side)).font(.subheadline.bold())
                    if conflict.newer == side { Text("Newer").font(.caption).foregroundStyle(.secondary) }
                    valueDetails(value, field: conflict.field)
                }
                Spacer()
                Image(systemName: conflict.selected == side ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.tint)
            }
            .padding(10)
            .background(.quaternary, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(conflict.selected == side ? .isSelected : [])
        .disabled(state?.syncing == true || state?.applying == true)
    }

    @ViewBuilder
    private func valueDetails(_ value: IosMergeValue, field: IosMergeField) -> some View {
        if let collection = value.collection {
            Text(collectionTitle(collection)).foregroundStyle(value.removesCollection ? Color.red : Color.primary)
        }
        if field == .rating {
            if value.score == 0 {
                Text("Unrated")
            } else {
                Text("Rating \(Int(value.score)) of 10")
            }
        }
        if let comment = value.comment {
            Text(comment)
        } else if value.showsComment {
            Text("No Review").foregroundStyle(.secondary)
        }
        if !value.tags.isEmpty {
            LabeledContent("Tags", value: value.tags.joined(separator: ", "))
        } else if value.showsTags {
            Text("No Tags").foregroundStyle(.secondary)
        }
        if let privacy = value.privacy {
            Text(privacy.boolValue ? LocalizedStringKey("Private") : LocalizedStringKey("Public"))
        }
        if value.modifiedAtMillis > 0 {
            Text(nativeDate(value.modifiedAtMillis), format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sideTitle(_ side: IosMergeSide) -> LocalizedStringKey {
        side == .animeko ? "Animeko" : "Bangumi"
    }

    private func collectionTitle(_ code: String) -> LocalizedStringKey {
        switch code {
        case "WISH": "Plan to Watch"
        case "DOING": "Watching"
        case "DONE": "Completed"
        case "ON_HOLD": "On Hold"
        case "DROPPED": "Dropped"
        default: "Not Collected"
        }
    }

    private func fieldTitle(_ field: IosMergeField) -> LocalizedStringKey {
        switch field {
        case .collection: "Collection Status"
        case .rating: "Rating"
        case .comment: "Short Review"
        default: "Episodes"
        }
    }
}
