import SwiftUI
import UIKit
import application

struct NativePlaybackPage: View {
    let catalog: IosNativeCatalog
    let subjectId: Int32
    let episodeId: Int32

    @Environment(\.scenePhase) private var scenePhase
    @State private var handle: NativeScreenHandle<IosNativePlayback>?
    @State private var state: IosPlaybackState?
    @State private var speed: IosPlaybackSpeed?
    @State private var options: IosPlaybackOptions?
    @State private var fullscreen = false
    @State private var showSources = false
    @State private var showComments = false
    @State private var showEpisodes = false
    @State private var showPlaybackOptions = false
    @State private var denied = false

    var body: some View {
        Group {
            if let playback = handle?.value {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 0) {
                        video(playback)
                            .frame(height: fullscreen ? geometry.size.height : min(geometry.size.width * 9 / 16, geometry.size.height))
                        if !fullscreen {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    if let state, !state.episodeTitle.isEmpty {
                                        Text(state.episodeTitle).font(.title2.bold())
                                            .accessibilityAddTraits(.isHeader)
                                        Text(state.subjectTitle).foregroundStyle(.secondary)
                                    }
                                    Button("Playback Sources", systemImage: "arrow.triangle.branch") { showSources = true }
                                        .buttonStyle(.glass)
                                    if state != nil {
                                        Button("Choose Episode", systemImage: "list.number") { showEpisodes = true }
                                            .buttonStyle(.glass)
                                        Button("Comments", systemImage: "bubble.left.and.bubble.right") { showComments = true }
                                            .buttonStyle(.glass)
                                    }
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: fullscreen ? .all : [])
                .sheet(isPresented: $showSources) { NativePlaybackSources(playback: playback) }
                .sheet(isPresented: $showEpisodes) { NativePlaybackEpisodes(playback: playback) }
                .sheet(isPresented: $showPlaybackOptions) { NativePlaybackOptionsSheet(playback: playback, options: $options) }
                .sheet(isPresented: $showComments) {
                    let currentEpisode = state?.episodeId ?? episodeId
                    NativeCommentsSheet(catalog: catalog, location: .episode(subjectId, currentEpisode)) {
                        playback.openComments(episodeId: currentEpisode)
                    }
                }
                .onChange(of: state?.episodeId) { previous, current in
                    if previous != nil && previous != current { showComments = false }
                }
                .onChange(of: fullscreen) { _, value in playback.setFullscreen(fullscreen: value) }
                .task { await observeNative(playback.observeSpeed) { speed = $0 } }
                .task { await observeNative(playback.observeOptions) { options = $0 } }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: playback.didEnterBackground()
                    case .active: playback.didBecomeActive()
                    default: break
                    }
                }
            } else if denied {
                ContentUnavailableView("Episode Unavailable", systemImage: "play.slash")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(state?.episodeNumber.nonEmpty ?? String(localized: "Playback"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(fullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .statusBarHidden(fullscreen)
        .task {
            if handle == nil {
                guard let playback = catalog.openPlayback(subjectId: subjectId, episodeId: episodeId) else {
                    denied = true
                    return
                }
                handle = NativeScreenHandle(playback) { $0.close() }
            }
            if let current = handle {
                await observeNative(current.value.observe) { state = $0 }
            }
        }
    }

    private func video(_ playback: IosNativePlayback) -> some View {
        NativeVideoSurface(playback: playback, fullscreen: fullscreen)
            .background(.black)
            .accessibilityHidden(true)
            .overlay(alignment: .center) {
                switch state?.status {
                case .loading, nil:
                    ProgressView().tint(.white)
                case .failed:
                    Button("Retry Playback", systemImage: "arrow.clockwise", action: playback.retry)
                        .buttonStyle(.glass)
                case .idle:
                    Button("Choose a Source") { showSources = true }.buttonStyle(.glass)
                default:
                    EmptyView()
                }
            }
            .overlay(alignment: .topLeading) {
                if options?.showAutoSkip == true {
                    Button("Keep Playing Opening or Ending", action: playback.continueOpeningOrEnding)
                        .buttonStyle(.glass)
                        .padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    NativePlaybackScrubber(playback: playback)
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("Back 10 Seconds", systemImage: "gobackward.10") { playback.seekBy(offsetMillis: -10_000) }
                            Button(
                                state?.isPlaying == true ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"),
                                systemImage: state?.isPlaying == true ? "pause.fill" : "play.fill",
                                action: playback.togglePlayback
                            )
                            Button("Forward 10 Seconds", systemImage: "goforward.10") { playback.seekBy(offsetMillis: 10_000) }
                            Menu("Player Options", systemImage: "ellipsis") {
                                Button("Playback Sources", systemImage: "arrow.triangle.branch") { showSources = true }
                                Button("Choose Episode", systemImage: "list.number") { showEpisodes = true }
                                if options?.audio != nil || options?.aspect != nil || options?.enhancement != nil {
                                    Button("Audio and Video", systemImage: "slider.horizontal.3") { showPlaybackOptions = true }
                                }
                                Button("Skip Opening or Ending", systemImage: "forward.end", action: playback.skipOpeningOrEnding)
                                    .disabled(state?.status != .ready)
                                Toggle("Danmaku", isOn: Binding(
                                    get: { state?.danmakuEnabled == true },
                                    set: { playback.setDanmakuEnabled(enabled: $0) }
                                ))
                                if let speed, !speed.options.isEmpty {
                                    Menu("Playback Speed", systemImage: "speedometer") {
                                        ForEach(speed.options.map(\.floatValue), id: \.self) { value in
                                            Button {
                                                playback.setPlaybackSpeed(value: value)
                                            } label: {
                                                let formatted = value.formatted(.number.precision(.fractionLength(0...2)))
                                                if value == speed.current {
                                                    Label("\(formatted)×", systemImage: "checkmark")
                                                } else {
                                                    Text("\(formatted)×")
                                                }
                                            }
                                        }
                                    }
                                }
                                Button("Next Episode", systemImage: "forward.end", action: playback.selectNextEpisode)
                                    .disabled(state?.hasNextEpisode != true)
                                Button("Picture in Picture", systemImage: "pip.enter", action: playback.enterPictureInPicture)
                                    .disabled(state?.canEnterPictureInPicture != true)
                            }
                            Button(
                                fullscreen ? LocalizedStringKey("Exit Full Screen") : LocalizedStringKey("Full Screen"),
                                systemImage: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                            ) { fullscreen.toggle() }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                    }
                }
                .padding(12)
            }
            .environment(\.colorScheme, .dark)
    }
}

private struct NativePlaybackOptionsSheet: View {
    let playback: IosNativePlayback
    @Binding var options: IosPlaybackOptions?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let audio = options?.audio {
                    Section("Audio") {
                        Slider(value: Binding(
                            get: { Double(options?.audio?.level ?? audio.level) },
                            set: { playback.setVolume(value: Float($0)) }
                        ), in: 0...Double(max(audio.maximum, .leastNonzeroMagnitude))) {
                            Text("Player Volume")
                        }
                        .disabled(audio.maximum <= 0)
                        Toggle("Mute", isOn: Binding(
                            get: { options?.audio?.muted == true },
                            set: { value in
                                if options?.audio?.muted != value { playback.toggleMute() }
                            }
                        ))
                    }
                }
                if let options, options.aspect != nil || options.enhancement != nil {
                    Section("Video") {
                        if let aspect = options.aspect {
                            Picker("Video Fit", selection: Binding(
                                get: { aspect },
                                set: { playback.setAspect(value: $0) }
                            )) {
                                Text("Fit").tag(IosPlaybackAspect.fit)
                                Text("Fill").tag(IosPlaybackAspect.crop)
                                Text("Stretch").tag(IosPlaybackAspect.stretch)
                            }
                        }
                        if let enhancement = options.enhancement {
                            Picker("Video Enhancement", selection: Binding(
                                get: { enhancement },
                                set: { playback.setEnhancement(value: $0) }
                            )) {
                                Text("Off").tag(IosPlaybackEnhancement.off)
                                Text("Performance").tag(IosPlaybackEnhancement.performance)
                                Text("Quality").tag(IosPlaybackEnhancement.quality)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Audio and Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct NativePlaybackEpisodes: View {
    let playback: IosNativePlayback
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [IosPlaybackEpisode]?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let episodes {
                        if episodes.isEmpty {
                            ContentUnavailableView("No Episodes", systemImage: "list.number")
                        }
                        ForEach(episodes, id: \.id) { episode in
                            Button {
                                playback.selectEpisode(id: episode.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(episode.number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(episode.title)
                                    Spacer()
                                    if episode.selected {
                                        Image(systemName: "play.fill").accessibilityLabel("Now Playing")
                                    } else if episode.watched {
                                        Image(systemName: "checkmark.circle").accessibilityLabel("Watched")
                                    }
                                }
                            }
                            .disabled(!episode.published || episode.selected)
                            .accessibilityAddTraits(episode.selected ? .isSelected : [])
                            .id(episode.id)
                        }
                    } else {
                        ProgressView()
                    }
                }
                .onChange(of: episodes?.first(where: \.selected)?.id, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .navigationTitle("Choose Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await observeNative(playback.observeEpisodes) { episodes = $0 } }
    }
}

private struct NativePlaybackScrubber: View {
    let playback: IosNativePlayback

    @State private var progress: IosPlaybackProgress?
    @State private var draggedPosition: Double?

    var body: some View {
        let duration = Double(progress?.durationMillis ?? 0)
        Slider(
            value: Binding(
                get: { min(max(draggedPosition ?? Double(progress?.positionMillis ?? 0), 0), max(duration, 1)) },
                set: { draggedPosition = $0 }
            ),
            in: 0...max(duration, 1),
            onEditingChanged: { editing in
                if !editing, let draggedPosition {
                    playback.seekTo(positionMillis: Int64(draggedPosition))
                    self.draggedPosition = nil
                }
            }
        ) {
            Text("Playback Position")
        }
        .disabled(duration == 0)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .task {
            await observeNative(playback.observeProgress) { progress = $0 }
        }
    }
}

private struct NativePlaybackSources: View {
    let playback: IosNativePlayback
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [IosPlaybackLine]?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        NativeManualBrowsePage(browse: playback.openManualBrowse()) { dismiss() }
                    } label: {
                        Label("Find Manually", systemImage: "magnifyingglass")
                    }
                }
                ForEach(lines ?? [], id: \.mediaId) { line in
                    Button {
                        playback.selectLine(mediaId: line.mediaId)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(line.title)
                                Text(line.sourceName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if line.selected { Image(systemName: "checkmark") }
                        }
                    }
                }
                if lines?.isEmpty == true {
                    ContentUnavailableView("No Sources Available", systemImage: "play.slash")
                }
            }
            .overlay(alignment: .bottom) { if lines == nil { ProgressView().padding() } }
            .navigationTitle("Playback Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Search Sources Again", systemImage: "arrow.clockwise", action: playback.retry)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await observeNative(playback.observeLines) { lines = $0 }
        }
    }
}

private struct NativeVideoSurface: UIViewControllerRepresentable {
    typealias Context = UIViewControllerRepresentableContext<Self>

    let playback: IosNativePlayback
    let fullscreen: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        playback.makeVideoController()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.updateOrientation(in: controller, fullscreen: fullscreen)
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.updateOrientation(in: controller, fullscreen: false)
    }

    @MainActor
    final class Coordinator {
        private var fullscreen = false
        private weak var scene: UIWindowScene?

        func updateOrientation(in controller: UIViewController, fullscreen: Bool) {
            guard self.fullscreen != fullscreen, UIDevice.current.userInterfaceIdiom == .phone else { return }
            self.fullscreen = fullscreen
            scene = controller.viewIfLoaded?.window?.windowScene ?? scene
            AppDelegate.orientationLock = fullscreen ? .landscape : nil
            scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: fullscreen ? .landscape : .portrait))
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
