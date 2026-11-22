import SwiftUI
import application

struct NativeDownloadsPage: View {
    let catalog: IosNativeCatalog

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
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
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
        Group {
            if item.canPlay && subjectId > 0 && item.episodeId > 0 {
                NavigationLink(value: NativeRoute.episode(subjectId: subjectId, episodeId: item.episodeId)) {
                    detail
                }
            } else {
                detail
            }
        }
        .contextMenu {
            if !item.isBusy {
                if item.status == .downloading {
                    Button("Pause Download", systemImage: "pause", action: pause)
                } else if item.status == .paused || item.status == .failed {
                    Button("Resume Download", systemImage: "arrow.clockwise", action: resume)
                }
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
            if item.status == .downloading || item.status == .paused {
                ProgressView(value: item.progress)
            }
            switch item.status {
            case .paused:
                Text("Paused").font(.footnote).foregroundStyle(.secondary)
            case .failed:
                Text("Failed").font(.footnote).foregroundStyle(.secondary)
            case .completed:
                Text("Completed").font(.footnote).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }
}
