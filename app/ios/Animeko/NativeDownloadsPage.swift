import SwiftUI
import application

struct NativeDownloadsPage: View {
    let catalog: IosNativeCatalog
    let openExplore: () -> Void

    @State private var handle: NativeScreenHandle<IosNativeDownloads>?
    @State private var state: IosDownloadsState?
    @State private var pendingDeletion: IosDownloadRow?

    var body: some View {
        List {
            ForEach(state?.groups ?? [], id: \.subjectId) { group in
                Section(group.title) {
                    ForEach(group.downloads, id: \.downloadId) { item in
                        row(item, subjectId: group.subjectId)
                    }
                    NavigationLink("Manage Downloads", value: NativeRoute.subjectDownloads(group.subjectId))
                }
            }
        }
        .overlay {
            if let state, !state.isLoading && state.groups.isEmpty {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.circle")
                } actions: {
                    Button("Explore", action: openExplore).buttonStyle(.glass)
                }
            } else if state?.isLoading != false {
                ProgressView()
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog(
            "Delete Download?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { item in
            Button("Delete", role: .destructive) { handle?.value.delete(downloadId: item.downloadId) }
        } message: { item in
            Text(item.title)
        }
        .alert(
            "Download Action Failed",
            isPresented: Binding(
                get: { (state?.operationFailures ?? 0) > 0 },
                set: { if !$0 { handle?.value.dismissFailures() } }
            )
        ) {
            Button("OK", role: .cancel) { handle?.value.dismissFailures() }
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openDownloads()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }

    private func row(_ item: IosDownloadRow, subjectId: Int32) -> some View {
        NativeDownloadItem(
            item: item,
            subjectId: subjectId,
            pause: { handle?.value.pause(downloadId: item.downloadId) },
            resume: { handle?.value.resume(downloadId: item.downloadId) },
            delete: { pendingDeletion = item }
        )
    }
}

struct NativeDownloadItem: View {
    let item: IosDownloadRow
    let subjectId: Int32
    let pause: () -> Void
    let resume: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if item.canPlay && subjectId > 0 && item.episodeId > 0 {
                NavigationLink(value: NativeRoute.episode(subjectId: subjectId, episodeId: item.episodeId)) {
                    detail
                }
            } else {
                detail
            }
            if item.isBusy {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download Actions")
            }
        }
        .contextMenu { if !item.isBusy { actions } }
    }

    @ViewBuilder
    private var actions: some View {
        if item.status == .downloading {
            Button("Pause Download", systemImage: "pause", action: pause)
        } else if item.status == .paused || item.status == .failed {
            Button("Resume Download", systemImage: "arrow.clockwise", action: resume)
        }
        Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.subheadline.weight(.semibold))
            if item.status == .downloading || item.status == .paused {
                ProgressView(value: item.progress)
            }
            HStack {
                statusLabel
                if item.status == .downloading || item.status == .paused {
                    Spacer(minLength: 5)
                    Text(item.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.status {
        case .downloading: Label("Downloading", systemImage: "arrow.down.circle")
        case .paused: Label("Paused", systemImage: "pause.circle")
        case .failed: Label("Failed", systemImage: "exclamationmark.circle").foregroundStyle(Color.red)
        case .completed: Label("Completed", systemImage: "checkmark.circle")
        default: EmptyView()
        }
    }
}
