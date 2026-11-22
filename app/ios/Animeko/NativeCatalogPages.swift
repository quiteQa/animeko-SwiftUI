import Foundation
import SwiftUI
import application

struct NativeExplorePage: View {
    let catalog: IosNativeCatalog
    @State private var handle: NativeScreenHandle<IosNativeExplore>?
    @State private var state: IosCatalogState?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink(value: NativeRoute.schedule) {
                    Label("Airing Schedule", systemImage: "calendar")
                }
                .buttonStyle(.glass)
                if let state, !state.subjects.isEmpty {
                    HStack {
                        Text("Trending")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        NavigationLink("See All", value: NativeRoute.ranking)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 16)], spacing: 20) {
                        ForEach(state.subjects, id: \.subjectId) { subject in
                            NavigationLink(value: NativeRoute.subject(subject.subjectId)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    NativeCover(subject: subject)
                                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                    Text(subject.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2, reservesSpace: true)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    NativeCatalogFeedback(status: state?.status, retry: { handle?.value.retry() })
                        .padding(.vertical, 32)
                }
            }
            .frame(maxWidth: 960)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Explore")
        .refreshable { handle?.value.refresh() }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openExplore()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }
}

struct NativeRankingPage: View {
    let catalog: IosNativeCatalog
    @State private var handle: NativeScreenHandle<IosNativeRankings>?
    @State private var state: IosCatalogState?

    var body: some View {
        NativeCatalogList(state: state, loadMore: { handle?.value.loadMore() }, retry: { handle?.value.retry() }) {
            ContentUnavailableView("No Results", systemImage: "chart.line.uptrend.xyaxis")
        }
        .navigationTitle("Trending")
        .refreshable { handle?.value.refresh() }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openRankings()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }
}

struct NativeSchedulePage: View {
    let catalog: IosNativeCatalog
    @State private var handle: NativeScreenHandle<IosNativeSchedule>?
    @State private var state: IosAiringSchedule?
    @State private var selectedDate: Int64?

    private var activeDay: IosAiringDay? {
        state?.days.first(where: { $0.dateMillis == selectedDate })
    }

    var body: some View {
        List {
            if let activeDay {
                Section {
                    ForEach(activeDay.episodes, id: \.episodeId) { entry in
                        NavigationLink(value: NativeRoute.subject(entry.subject.subjectId)) {
                            HStack(spacing: 12) {
                                NativeCover(subject: entry.subject)
                                    .frame(width: 48, height: 68)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.subject.title)
                                    Text([entry.episodeNumber, entry.episodeTitle].compactMap { $0 }.joined(separator: " · "))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let time = entry.airTimeMillis {
                                    Text(date(time.int64Value), format: .dateTime.hour().minute())
                                        .font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                } header: {
                    Text(date(activeDay.dateMillis), format: .dateTime.weekday(.wide).month().day())
                }
            }
        }
        .overlay {
            if state?.status != .ready || activeDay?.episodes.isEmpty == true {
                NativeCatalogFeedback(status: state?.status, retry: { handle?.value.refresh() })
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Date", selection: $selectedDate) {
                    ForEach(state?.days ?? [], id: \.dateMillis) { day in
                        if day.isToday {
                            Text("Today").tag(Optional(day.dateMillis))
                        } else {
                            Text(date(day.dateMillis), format: .dateTime.weekday(.abbreviated).month().day())
                                .tag(Optional(day.dateMillis))
                        }
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .navigationTitle("Airing Schedule")
        .refreshable { handle?.value.refresh() }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openSchedule()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { schedule in
                state = schedule
                if !schedule.days.contains(where: { $0.dateMillis == selectedDate }) {
                    selectedDate = schedule.days.first(where: \.isToday)?.dateMillis
                }
            }
        }
    }

    private func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

struct NativeSearchPage: View {
    let catalog: IosNativeCatalog
    let query: String

    @State private var handle: NativeScreenHandle<IosNativeSearch>?
    @State private var state: IosCatalogState?

    var body: some View {
        NativeCatalogList(state: state, loadMore: { handle?.value.loadMore() }, retry: { handle?.value.retry() }) {
            ContentUnavailableView("Search Anime", systemImage: "magnifyingglass")
        }
        .navigationTitle("Search")
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openSearch()) { $0.close() }
            handle = current
            current.value.submit(keywords: query)
            await observeNative(current.value.observe) { state = $0 }
        }
        .onChange(of: query) { _, value in
            state = nil
            handle?.value.submit(keywords: value)
        }
    }
}

struct NativeCollectionPage: View {
    let catalog: IosNativeCatalog
    @State private var handle: NativeScreenHandle<IosNativeCollections>?
    @State private var state: IosCatalogState?
    @State private var filter: IosCollectionFilter = .watching

    var body: some View {
        NativeCatalogList(state: state, loadMore: { handle?.value.loadMore() }, retry: { handle?.value.retry() }) {
            ContentUnavailableView("No Anime in This Collection", systemImage: "star")
        }
        .navigationTitle("Collection")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Collection Status", selection: $filter) {
                    Text("Watching").tag(IosCollectionFilter.watching)
                    Text("Plan to Watch").tag(IosCollectionFilter.wanted)
                    Text("Completed").tag(IosCollectionFilter.completed)
                    Text("On Hold").tag(IosCollectionFilter.onHold)
                    Text("Dropped").tag(IosCollectionFilter.dropped)
                }
                .pickerStyle(.menu)
            }
        }
        .refreshable { handle?.value.refresh() }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openCollections()) { $0.close() }
            handle = current
            current.value.select(filter: filter)
            await observeNative(current.value.observe) { state = $0 }
        }
        .onChange(of: filter) { _, value in
            state = nil
            handle?.value.select(filter: value)
        }
    }
}

private struct NativeCatalogList<EmptyContent: View>: View {
    let state: IosCatalogState?
    let loadMore: () -> Void
    let retry: () -> Void
    @ViewBuilder let emptyContent: () -> EmptyContent

    var body: some View {
        List {
            ForEach(state?.subjects ?? [], id: \.subjectId) { subject in
                NavigationLink(value: NativeRoute.subject(subject.subjectId)) {
                    HStack(spacing: 12) {
                        if subject.rank > 0 {
                            Text(subject.rank, format: .number)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        NativeCover(subject: subject)
                            .frame(width: 48, height: 68)
                        Text(subject.title)
                    }
                }
            }
            if state?.appendFailed == true {
                Button("Try Again", action: retry)
            } else if state?.canLoadMore == true {
                Button("Load More", action: loadMore)
            }
        }
        .overlay {
            if let state, state.subjects.isEmpty && !state.canLoadMore && !state.appendFailed {
                switch state.status {
                case .idle, .ready: emptyContent()
                default: NativeCatalogFeedback(status: state.status, retry: retry)
                }
            } else if state == nil {
                ProgressView()
            }
        }
    }
}

struct NativeSubjectPage: View {
    let catalog: IosNativeCatalog
    let subjectId: Int32
    let signIn: () -> Void
    @State private var handle: NativeScreenHandle<IosNativeSubject>?
    @State private var state: IosSubjectState?
    @State private var collection: IosSubjectCollectionState?

    var body: some View {
        List {
            if let state, let subject = state.subject {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        NativeCover(subject: subject)
                            .frame(width: 116, height: 164)
                        Text(subject.title)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        if let collection, state.status == .ready {
                            collectionControl(collection)
                        }
                        if !state.summary.isEmpty {
                            Text(state.summary)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 8)
                }
                Section("Episodes") {
                    if state.episodesLoading {
                        ProgressView()
                    } else if state.episodes.isEmpty {
                        Text("No Episodes").foregroundStyle(.secondary)
                    }
                    ForEach(state.episodes, id: \.episodeId) { episode in
                        NavigationLink(value: NativeRoute.episode(subjectId: subjectId, episodeId: episode.episodeId)) {
                            HStack {
                                if let imageUrl = episode.imageUrl, let url = URL(string: imageUrl) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Rectangle().fill(.quaternary)
                                    }
                                    .frame(width: 64, height: 36)
                                    .clipShape(.rect(cornerRadius: 6))
                                    .accessibilityHidden(true)
                                }
                                Text(episode.number)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(episode.title)
                                if episode.watched {
                                    Spacer()
                                    Image(systemName: "checkmark.circle")
                                        .accessibilityLabel("Watched")
                                }
                            }
                        }
                        .disabled(!episode.canPlay)
                    }
                }
                if !state.characters.isEmpty {
                    Section("Characters") {
                        ForEach(state.characters, id: \.id) { character in
                            NavigationLink(value: NativeRoute.character(character.id)) {
                                NativePersonLabel(person: character)
                            }
                        }
                    }
                }
                if !state.staff.isEmpty {
                    Section("Staff") {
                        ForEach(state.staff, id: \.id) { person in
                            NavigationLink(value: NativeRoute.person(person.id)) {
                                NativePersonLabel(person: person)
                            }
                        }
                    }
                }
                if state.status == .ready {
                    Section {
                        NavigationLink(value: NativeRoute.subjectDownloads(subjectId)) {
                            Label("Manage Downloads", systemImage: "arrow.down.circle")
                        }
                        NavigationLink("Series Connections", value: NativeRoute.series(subjectId))
                    }
                }
            } else {
                NativeCatalogFeedback(status: state?.status, retry: { handle?.value.retry() })
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(state?.subject?.title ?? String(localized: "Anime"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Mark All Episodes as Watched?",
            isPresented: Binding(
                get: { collection?.offerMarkAllWatched == true && collection?.working == false },
                set: { if !$0 { handle?.value.dismissMarkAllWatched() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Mark All as Watched") { handle?.value.markAllWatched() }
            Button("Cancel", role: .cancel) { handle?.value.dismissMarkAllWatched() }
        }
        .alert("Couldn’t Update Collection", isPresented: Binding(
            get: { collection?.failed == true },
            set: { if !$0 { handle?.value.dismissCollectionFailure() } }
        )) {
            Button("OK", role: .cancel) {}
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openSubject(subjectId: subjectId)) { $0.close() }
            handle = current
            async let observeCollection: Void = observeNative(current.value.observeCollection) { collection = $0 }
            await observeNative(current.value.observe) { state = $0 }
            await observeCollection
        }
    }

    @ViewBuilder
    private func collectionControl(_ collection: IosSubjectCollectionState) -> some View {
        if collection.working {
            ProgressView()
        } else if collection.signedIn {
            Menu {
                ForEach(
                    [IosCollectionFilter.wanted, .watching, .completed, .onHold, .dropped],
                    id: \.self
                ) { filter in
                    Button {
                        handle?.value.setCollection(filter: filter)
                    } label: {
                        if collection.status == filter {
                            Label(collectionTitle(filter), systemImage: "checkmark")
                        } else {
                            Text(collectionTitle(filter))
                        }
                    }
                }
                if collection.status != nil {
                    Button("Remove from Collection", role: .destructive) { handle?.value.setCollection(filter: nil) }
                }
            } label: {
                Label(collectionTitle(collection.status), systemImage: collection.status == nil ? "star" : "star.fill")
            }
            .buttonStyle(.glass)
            .disabled(!collection.available)
            .accessibilityHint("Change Collection Status")
        } else {
            Button("Sign In to Collect", systemImage: "star", action: signIn).buttonStyle(.glass)
        }
    }

    private func collectionTitle(_ filter: IosCollectionFilter?) -> LocalizedStringKey {
        switch filter {
        case .wanted: "Plan to Watch"
        case .watching: "Watching"
        case .completed: "Completed"
        case .onHold: "On Hold"
        case .dropped: "Dropped"
        default: "Add to Collection"
        }
    }
}

struct NativeCover: View {
    let subject: IosSubjectCard

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if !subject.obscuresCover, let url = URL(string: subject.coverUrl), !subject.coverUrl.isEmpty {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: subject.obscuresCover ? "eye.slash" : "photo")
            .foregroundStyle(.secondary)
    }
}

private struct NativeCatalogFeedback: View {
    let status: IosLoadStatus?
    let retry: () -> Void

    var body: some View {
        switch status {
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Load Content", systemImage: "exclamationmark.circle")
            } actions: {
                Button("Try Again", action: retry)
            }
        case .ready:
            ContentUnavailableView("No Results", systemImage: "tray")
        default:
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}
