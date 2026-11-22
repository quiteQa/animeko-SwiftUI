import Foundation
import SwiftUI
import application

struct NativeManualBrowsePage: View {
    let browse: IosNativeManualBrowse
    var downloading = false
    let onPlayed: () -> Void

    @State private var state: IosManualBrowseState?
    @State private var keyword = ""
    @State private var keywordInitialized = false
    @State private var showEpisodes = false

    var body: some View {
        List {
            if let state, let sourceId = state.selectedSourceId {
                Picker("Media Source", selection: Binding(
                    get: { sourceId },
                    set: { browse.selectSource(id: $0) }
                )) {
                    ForEach(state.sources, id: \.id) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                Section("Search Results") {
                    if state.searchStatus == .ready, state.results.isEmpty {
                        Text("No Results").foregroundStyle(.secondary)
                    }
                    NativeManualBrowseFeedback(status: state.searchStatus, captcha: state.searchBlockedByCaptcha, retry: browse.retry)
                    ForEach(state.results, id: \.url) { result in
                        Button {
                            showEpisodes = browse.openSubject(url: result.url, sourceId: sourceId)
                        } label: {
                            HStack {
                                Text(result.name)
                                Spacer()
                                Image(systemName: "chevron.forward").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if state?.searchStatus == .loading || state == nil {
                ProgressView()
            } else {
                ContentUnavailableView("No Browsable Sources", systemImage: "magnifyingglass")
            }
        }
        .navigationTitle("Find Manually")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $keyword, prompt: "Search Anime")
        .onSubmit(of: .search) {
            if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browse.search(keyword: keyword)
            }
        }
        .navigationDestination(isPresented: $showEpisodes) {
            NativeManualEpisodePage(browse: browse, downloading: downloading, onPlayed: onPlayed)
        }
        .onChange(of: showEpisodes) { _, shown in
            if !shown { browse.closeSubject() }
        }
        .task {
            if !showEpisodes { browse.closeSubject() }
            await observeNative(browse.observe) { value in
                state = value
                if !keywordInitialized, !value.keyword.isEmpty {
                    keyword = value.keyword
                    keywordInitialized = true
                }
                if value.searchStatus == .idle, value.selectedSourceId != nil, !value.keyword.isEmpty {
                    browse.searchIfNeeded()
                }
            }
        }
    }
}

private struct NativeManualEpisodePage: View {
    let browse: IosNativeManualBrowse
    let downloading: Bool
    let onPlayed: () -> Void

    @State private var state: IosManualBrowseState?
    @State private var failedToPlay = false

    var body: some View {
        List {
            if let state {
                Section {
                    if let number = state.targetEpisodeNumber {
                        if downloading {
                            Text("Download as Episode \(number)")
                        } else {
                            Text("Play as Episode \(number)")
                        }
                    }
                    if !downloading {
                        Toggle("Remember Selection", isOn: Binding(
                            get: { state.rememberSelection },
                            set: { browse.setRememberSelection(enabled: $0) }
                        ))
                    }
                }
                if state.channels.count > 1 {
                    Picker("Playback Line", selection: Binding(
                        get: { state.selectedChannelIndex },
                        set: { browse.selectChannel(index: $0) }
                    )) {
                        ForEach(state.channels, id: \.index) { channel in
                            if let name = channel.name, !name.isEmpty {
                                Text(name).tag(channel.index)
                            } else {
                                Text("Line \(Int(channel.index) + 1)").tag(channel.index)
                            }
                        }
                    }
                }
                Section("Episodes") {
                    if state.isPlaying { ProgressView() }
                    NativeManualBrowseFeedback(status: state.episodeStatus, captcha: state.episodeBlockedByCaptcha, retry: browse.retry)
                    if state.episodeStatus == .ready, state.episodes.isEmpty {
                        Text("No Episodes").foregroundStyle(.secondary)
                    }
                    ForEach(state.episodes, id: \.index) { episode in
                        Button {
                            browse.play(index: episode.index) { result in
                                Task { @MainActor in
                                    if result == .ready {
                                        onPlayed()
                                    } else {
                                        failedToPlay = true
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(episode.name ?? "")
                                Spacer()
                                if state.selectedEpisodeIndex == episode.index {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .accessibilityAddTraits(state.selectedEpisodeIndex == episode.index ? .isSelected : [])
                        .disabled(state.targetEpisodeNumber == nil)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .disabled(state?.isPlaying == true)
        .navigationTitle(state?.title ?? String(localized: "Episodes"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            downloading ? LocalizedStringKey("Couldn’t Start Download") : LocalizedStringKey("Couldn’t Play Selected Episode"),
            isPresented: $failedToPlay
        ) {
            Button("OK", role: .cancel) {}
        }
        .task { await observeNative(browse.observe) { state = $0 } }
    }
}

private struct NativeManualBrowseFeedback: View {
    let status: IosLoadStatus
    let captcha: Bool
    let retry: () -> Void

    var body: some View {
        if status == .loading {
            ProgressView()
        } else if status == .failed {
            if captcha {
                Label("This Source Requires a CAPTCHA", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.secondary)
            } else {
                Label("Couldn’t Load Content", systemImage: "exclamationmark.circle")
                Button("Try Again", action: retry)
            }
        }
    }
}
