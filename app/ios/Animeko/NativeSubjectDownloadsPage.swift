import SwiftUI
import application

struct NativeSubjectDownloadsPage: View {
    let catalog: IosNativeCatalog
    let subjectId: Int32

    @State private var handle: NativeScreenHandle<IosNativeSubjectDownloads>?
    @State private var state: IosSubjectDownloadsState?
    @State private var request: IosDownloadRequestState?
    @State private var showPicker = false
    @State private var pendingDeletion: IosDownloadRow?

    var body: some View {
        List {
            if let state, let downloads = handle?.value {
                if state.status == .failed {
                    Label("Couldn’t Load Content", systemImage: "exclamationmark.circle")
                    Button("Try Again", action: downloads.reload)
                }
                if state.working { ProgressView() }
                if request?.step == .sources || request?.step == .episodes {
                    Section {
                        Button("Continue Download Setup") { showPicker = true }
                        Button("Cancel Download Setup", role: .cancel, action: downloads.cancelRequest)
                    }
                }
                if !state.downloads.isEmpty {
                    Section("Downloads") {
                        ForEach(state.downloads, id: \.downloadId) { item in
                            NativeDownloadItem(
                                item: item,
                                subjectId: subjectId,
                                pause: { downloads.pause(downloadId: item.downloadId) },
                                resume: { downloads.resume(downloadId: item.downloadId) },
                                delete: { pendingDeletion = item }
                            )
                        }
                    }
                }
                if !state.episodes.isEmpty {
                    Section("Episodes") {
                        ForEach(state.episodes, id: \.episodeId) { episode in
                            Button {
                                if request?.step == .sources || request?.step == .episodes { showPicker = true }
                                downloads.requestDownload(episodeId: episode.episodeId)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(episode.number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(episode.title)
                                    Spacer()
                                    Image(systemName: "arrow.down.circle")
                                }
                            }
                            .disabled(!episode.published || state.working)
                        }
                    }
                }
                if state.status == .loading && state.downloads.isEmpty && state.episodes.isEmpty {
                    ProgressView()
                } else if state.status == .ready && state.downloads.isEmpty && state.episodes.isEmpty {
                    ContentUnavailableView("No Episodes", systemImage: "arrow.down.circle")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(state?.title ?? String(localized: "Downloads"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { handle?.value.reload() }
        .sheet(isPresented: $showPicker) {
            if let downloads = handle?.value {
                NativeDownloadPicker(downloads: downloads, request: $request)
                    .presentationDetents([.large])
            }
        }
        .alert(alertTitle, isPresented: Binding(
            get: { request?.step == .failed || (state?.operationFailures ?? 0) > 0 },
            set: { if !$0 { dismissFailure() } }
        )) {
            Button("OK", role: .cancel, action: dismissFailure)
        }
        .confirmationDialog(
            "Delete Download?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { item in
            Button("Delete", role: .destructive) { handle?.value.delete(downloadId: item.downloadId) }
        } message: { item in
            Text(item.title)
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openSubjectDownloads(subjectId: subjectId)) { $0.close() }
            handle = current
            async let page: Void = observeNative(current.value.observe) { state = $0 }
            await observeNative(current.value.observeRequest) { value in
                let previous = request?.step
                request = value
                if value.step == .none || value.step == .failed {
                    showPicker = false
                } else if previous == nil || previous == IosDownloadStep.none || previous == .failed {
                    showPicker = true
                }
            }
            await page
        }
    }

    private var alertTitle: LocalizedStringKey {
        request?.step == .failed ? "Couldn’t Start Download" : "Download Action Failed"
    }

    private func dismissFailure() {
        if request?.step == .failed { handle?.value.cancelRequest() }
        handle?.value.dismissFailures()
    }
}

private struct NativeDownloadPicker: View {
    let downloads: IosNativeSubjectDownloads
    @Binding var request: IosDownloadRequestState?

    @Environment(\.dismiss) private var dismiss
    @State private var manualBrowse: IosNativeManualBrowse?

    var body: some View {
        NavigationStack {
            Group {
                if let request, request.step == .episodes {
                    NativeBatchEpisodePicker(downloads: downloads, options: request.options)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Choose Source Again", systemImage: "chevron.backward", action: downloads.chooseSourceAgain)
                            }
                        }
                } else {
                    sourceList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Cancel Download Setup", role: .destructive, action: downloads.cancelRequest)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { manualBrowse != nil },
                set: { if !$0 { manualBrowse = nil } }
            )) {
                if let manualBrowse {
                    NativeManualBrowsePage(browse: manualBrowse, downloading: true) { self.manualBrowse = nil }
                }
            }
            .onChange(of: request?.step) { _, step in
                if step != .sources { manualBrowse = nil }
            }
        }
    }

    private var sourceList: some View {
        List {
            if request?.canBrowse == true {
                Button("Find Manually", systemImage: "magnifyingglass") { manualBrowse = downloads.openManualBrowse() }
            }
            if let request, request.step == .sources {
                ForEach(request.candidates, id: \.id) { candidate in
                    Button {
                        downloads.select(candidate: candidate)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.title.isEmpty ? candidate.sourceName : candidate.title)
                            Text([candidate.sourceName, candidate.line].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if request.loading {
                    ProgressView("Searching Sources")
                } else if request.candidates.isEmpty {
                    ContentUnavailableView("No Sources Available", systemImage: "magnifyingglass")
                }
            }
        }
        .navigationTitle("Choose Download Source")
        .refreshable { downloads.refreshSources() }
    }
}

private struct NativeBatchEpisodePicker: View {
    let downloads: IosNativeSubjectDownloads
    let options: [IosDownloadEpisodeOption]

    @State private var selected: Set<Int32>

    init(downloads: IosNativeSubjectDownloads, options: [IosDownloadEpisodeOption]) {
        self.downloads = downloads
        self.options = options
        _selected = State(initialValue: Self.availableFromCurrent(options))
    }

    var body: some View {
        List {
            Section {
                Button("Only This Episode") {
                    selected = Set(options.filter { $0.current && $0.availability == .available }.map(\.episodeId))
                }
                Button("From This Episode") { selected = Self.availableFromCurrent(options) }
                Button("All Available Episodes") {
                    selected = Set(options.filter { $0.availability == .available }.map(\.episodeId))
                }
            }
            Section("Episodes") {
                ForEach(options, id: \.episodeId) { episode in
                    Toggle(isOn: Binding(
                        get: { selected.contains(episode.episodeId) },
                        set: {
                            if $0 { selected.insert(episode.episodeId) } else { selected.remove(episode.episodeId) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text([episode.number, episode.title].filter { !$0.isEmpty }.joined(separator: " · "))
                            switch episode.availability {
                            case .available:
                                if let resource = episode.resource { Text(resource).font(.caption).foregroundStyle(.secondary) }
                            case .downloaded:
                                Text("Already Downloaded").font(.caption).foregroundStyle(.secondary)
                            default:
                                Text("No Matching Source").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(episode.availability != .available)
                }
            }
        }
        .navigationTitle("Choose Episodes")
        .safeAreaInset(edge: .bottom) {
            Button("Download Selected Episodes") {
                downloads.confirmEpisodes(ids: selected.sorted().map { KotlinInt(int: $0) })
            }
            .buttonStyle(.glassProminent)
            .disabled(selected.isEmpty)
            .padding()
        }
    }

    private static func availableFromCurrent(_ options: [IosDownloadEpisodeOption]) -> Set<Int32> {
        let start = options.firstIndex(where: \.current) ?? options.startIndex
        return Set(options.dropFirst(start).filter { $0.availability == .available }.map(\.episodeId))
    }
}
