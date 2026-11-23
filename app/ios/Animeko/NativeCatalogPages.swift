import Foundation
import SwiftUI
import application

struct NativeExplorePage: View {
    let catalog: IosNativeCatalog
    @State private var handle: NativeScreenHandle<IosNativeExplore>?
    @State private var state: IosCatalogState?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let featured = state?.subjects.first {
                    NavigationLink(value: NativeRoute.subject(featured.subjectId)) {
                        NativeExploreFeature(subject: featured)
                    }
                    .buttonStyle(.plain)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { shortcuts }
                    VStack(alignment: .leading, spacing: 8) { shortcuts }
                }
                .buttonStyle(.glass)
                .controlSize(.regular)

                if let state, state.subjects.count > 1 {
                    HStack {
                        Text("Trending")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        NavigationLink(value: NativeRoute.ranking) {
                            Label("See All", systemImage: "chevron.forward")
                                .labelStyle(.titleAndIcon)
                        }
                        .font(.subheadline)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 14)], spacing: 18) {
                        ForEach(state.subjects.dropFirst(), id: \.subjectId) { subject in
                            NativePosterLink(subject: subject)
                        }
                    }
                } else if state?.subjects.isEmpty != false {
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

    @ViewBuilder
    private var shortcuts: some View {
        NavigationLink(value: NativeRoute.schedule) {
            Label("Airing Schedule", systemImage: "calendar")
        }
        NavigationLink(value: NativeRoute.history) {
            Label("Playback History", systemImage: "clock.arrow.circlepath")
        }
    }
}

private struct NativeExploreFeature: View {
    let subject: IosSubjectCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Trending", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(subject.title)
                .font(.title2.weight(.bold))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Image(systemName: "arrow.right.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(12)
        .frame(maxWidth: 290, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 188)
        .background(alignment: .trailing) {
            NativeCover(subject: subject, cornerRadius: 0)
                .frame(width: 185)
                .mask {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let state, !state.days.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(state.days, id: \.dateMillis) { day in
                                scheduleDay(day)
                                    .id(day.dateMillis)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selectedDate, initial: true) { _, selected in
                        if let selected { proxy.scrollTo(selected, anchor: .center) }
                    }
                    .background(.bar)
                }
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
                    selectedDate = (schedule.days.first(where: \.isToday) ?? schedule.days.first)?.dateMillis
                }
            }
        }
    }

    private func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    private func scheduleDay(_ day: IosAiringDay) -> some View {
        let isSelected = day.dateMillis == selectedDate
        return Button { selectedDate = day.dateMillis } label: {
            VStack(spacing: 2) {
                if day.isToday {
                    Text("Today")
                } else {
                    Text(date(day.dateMillis), format: .dateTime.weekday(.abbreviated))
                }
                Text(date(day.dateMillis), format: .dateTime.month(.abbreviated).day())
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(isSelected ? Color.accentColor.opacity(0.17) : Color.secondary.opacity(0.09), in: Capsule())
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct NativeSearchPage: View {
    let catalog: IosNativeCatalog
    let query: String

    @State private var handle: NativeScreenHandle<IosNativeSearch>?
    @State private var state: IosCatalogState?

    var body: some View {
        NativeCatalogList(state: state, posterGrid: true, loadMore: { handle?.value.loadMore() }, retry: { handle?.value.retry() }) {
            if query.isEmpty {
                ContentUnavailableView("Search Anime", systemImage: "magnifyingglass")
            } else {
                ContentUnavailableView.search(text: query)
            }
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
    let signIn: () -> Void
    @State private var handle: NativeScreenHandle<IosNativeCollections>?
    @State private var state: IosCatalogState?
    @State private var filter: IosCollectionFilter = .watching

    var body: some View {
        NativeCatalogList(state: state, posterGrid: true, loadMore: { handle?.value.loadMore() }, retry: { handle?.value.retry() }) {
            if state?.requiresSignIn == true {
                ContentUnavailableView {
                    Label("Collection", systemImage: "star")
                } actions: {
                    Button("Sign In to Collect", action: signIn).buttonStyle(.glassProminent)
                }
            } else {
                ContentUnavailableView("No Anime in This Collection", systemImage: "star")
            }
        }
        .navigationTitle("Collection")
        .safeAreaInset(edge: .top, spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach([IosCollectionFilter.watching, .wanted, .completed, .onHold, .dropped], id: \.self) { option in
                        let selected = filter == option
                        Button { filter = option } label: {
                            Text(collectionTitle(option))
                                .font(.subheadline.weight(selected ? .semibold : .medium))
                                .padding(.horizontal, 13)
                                .frame(minHeight: 44)
                                .background(selected ? Color.accentColor.opacity(0.17) : Color.secondary.opacity(0.09), in: Capsule())
                                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .background(.bar)
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
    var posterGrid = false
    let loadMore: () -> Void
    let retry: () -> Void
    @ViewBuilder let emptyContent: () -> EmptyContent

    var body: some View {
        Group {
            if posterGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 18) {
                        ForEach(state?.subjects ?? [], id: \.subjectId) { subject in
                            NativePosterLink(subject: subject)
                        }
                    }
                    NativeActivityPagination(
                        canLoadMore: state?.canLoadMore == true, failed: state?.appendFailed == true,
                        loadMore: loadMore, retry: retry
                    )
                    .buttonStyle(.glass)
                    .padding(.vertical, 10)
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
            } else {
                rankedList
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

    private var rankedList: some View {
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
    }
}

private struct NativePosterLink: View {
    let subject: IosSubjectCard

    var body: some View {
        NavigationLink(value: NativeRoute.subject(subject.subjectId)) {
            VStack(alignment: .leading, spacing: 7) {
                NativeCover(subject: subject)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                Text(subject.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

struct NativeSubjectPage: View {
    let catalog: IosNativeCatalog
    let subjectId: Int32
    let signIn: () -> Void
    @State private var handle: NativeScreenHandle<IosNativeSubject>?
    @State private var state: IosSubjectState?
    @State private var collection: IosSubjectCollectionState?
    @State private var summaryExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let state, let subject = state.subject {
                    subjectHeader(subject, state: state)
                    if state.status == .ready {
                        if !state.summary.isEmpty {
                            DisclosureGroup(isExpanded: $summaryExpanded) {
                                Text(state.summary).frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(.top, 8)
                            } label: {
                                Text("Synopsis").font(.headline).accessibilityAddTraits(.isHeader)
                            }
                        }
                        episodesSection(state)
                        peopleSection("Characters", people: state.characters, canLoadMore: state.moreCharacters, failed: state.charactersAppendFailed,
                                      loadMore: { handle?.value.loadMoreCharacters() }, retry: { handle?.value.retryCharacters() })
                        peopleSection("Staff", people: state.staff, canLoadMore: state.moreStaff, failed: state.staffAppendFailed,
                                      loadMore: { handle?.value.loadMoreStaff() }, retry: { handle?.value.retryStaff() })
                        NavigationLink(value: NativeRoute.series(subjectId)) {
                            Label("Series Connections", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .buttonStyle(.glass)
                    } else {
                        NativeCatalogFeedback(status: state.status, retry: { handle?.value.retry() })
                    }
                } else {
                    NativeCatalogFeedback(status: state?.status, retry: { handle?.value.retry() })
                        .padding(.vertical, 32)
                }
            }
            .frame(maxWidth: 840)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
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
        .sheet(isPresented: Binding(
            get: { state?.rating?.showEditor == true },
            set: { if !$0 { handle?.value.closeRating() } }
        )) {
            if let rating = state?.rating {
                NativeSubjectRatingEditor(rating: rating, cancel: { handle?.value.closeRating() }) { score, review, privateRating in
                    handle?.value.saveRating(score: score, review: review, privateRating: privateRating)
                }
            }
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openSubject(subjectId: subjectId)) { $0.close() }
            handle = current
            async let observeCollection: Void = observeNative(current.value.observeCollection) { collection = $0 }
            await observeNative(current.value.observe) { state = $0 }
            await observeCollection
        }
    }

    private func subjectHeader(_ subject: IosSubjectCard, state: IosSubjectState) -> some View {
        let available = state.episodes.filter(\.canPlay)
        let episode = available.first { !$0.watched && $0.progress > 0 }
            ?? available.first { !$0.watched }
            ?? available.first
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                NativeCover(subject: subject).frame(width: 88, height: 126)
                VStack(alignment: .leading, spacing: 7) {
                    Text(subject.title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let rating = state.rating, rating.communityScore > 0 {
                        Label {
                            Text(rating.communityScore, format: .number.precision(.fractionLength(1)))
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "star.fill")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Rating")
                        .accessibilityValue(Text(rating.communityScore, format: .number.precision(.fractionLength(1))))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let episode {
                NavigationLink(value: NativeRoute.episode(subjectId: subjectId, episodeId: episode.episodeId)) {
                    Label(
                        episode.progress > 0 && !episode.watched ? LocalizedStringKey("Continue Watching") : LocalizedStringKey("Play Episode"),
                        systemImage: "play.fill"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityValue(Text(episode.number))
            }
            if state.status == .ready {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { subjectActions(state.rating) }
                    VStack(alignment: .leading, spacing: 8) { subjectActions(state.rating) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder
    private func subjectActions(_ rating: IosSubjectRating?) -> some View {
        if let collection { collectionControl(collection) }
        if let rating, rating.canEdit {
            Button("Rating", systemImage: rating.score > 0 ? "star.fill" : "star") { handle?.value.openRating() }
                .buttonStyle(.glass)
        }
        NavigationLink(value: NativeRoute.subjectDownloads(subjectId)) {
            Label("Downloads", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.glass)
    }

    private func episodesSection(_ state: IosSubjectState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episodes").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            if state.episodesLoading {
                ProgressView()
            } else if state.episodes.isEmpty {
                Text("No Episodes").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(state.episodes, id: \.episodeId) { episode in
                    NavigationLink(value: NativeRoute.episode(subjectId: subjectId, episodeId: episode.episodeId)) {
                        NativeEpisodeCardLabel(
                            number: episode.number, title: episode.title, imageUrl: episode.imageUrl,
                            published: episode.canPlay, watched: episode.watched, progress: episode.progress
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!episode.canPlay)
                }
            }
        }
    }

    @ViewBuilder
    private func peopleSection(
        _ title: LocalizedStringKey, people: [IosPersonReference], canLoadMore: Bool, failed: Bool,
        loadMore: @escaping () -> Void, retry: @escaping () -> Void
    ) -> some View {
        if !people.isEmpty || canLoadMore || failed {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 10) {
                    ForEach(people, id: \.id) { person in
                        NavigationLink(value: person.character ? NativeRoute.character(person.id) : .person(person.id)) {
                            NativePersonLabel(person: person)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                NativeActivityPagination(canLoadMore: canLoadMore, failed: failed, loadMore: loadMore, retry: retry)
                    .buttonStyle(.glass)
            }
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

private struct NativeSubjectRatingEditor: View {
    let rating: IosSubjectRating
    let cancel: () -> Void
    let save: (Int32, String, Bool) -> Void

    @State private var score: Int32
    @State private var review: String
    @State private var privateRating: Bool
    @State private var confirmDiscard = false

    init(rating: IosSubjectRating, cancel: @escaping () -> Void, save: @escaping (Int32, String, Bool) -> Void) {
        self.rating = rating
        self.cancel = cancel
        self.save = save
        _score = State(initialValue: rating.score)
        _review = State(initialValue: rating.comment)
        _privateRating = State(initialValue: rating.isPrivate)
    }

    private var hasChanges: Bool {
        score != rating.score || review != rating.comment || privateRating != rating.isPrivate
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Rating", selection: $score) {
                    Text("No Rating").tag(Int32(0))
                    ForEach(1...10, id: \.self) { value in
                        Text(value, format: .number).tag(Int32(value))
                    }
                }
                TextField("Write a Comment", text: $review, axis: .vertical)
                    .lineLimit(3...8)
                Toggle("Private", isOn: $privateRating)
            }
            .disabled(rating.saving)
            .navigationTitle("Rating")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { cancel() }
                    }
                    .disabled(rating.saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if rating.saving {
                        ProgressView()
                    } else {
                        Button("Save") { save(score, review, privateRating) }.disabled(!hasChanges)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(hasChanges || rating.saving)
        .confirmationDialog("Discard Changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive, action: cancel)
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct NativeCover: View {
    let subject: IosSubjectCard
    var cornerRadius: CGFloat = 10

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
            .clipShape(.rect(cornerRadius: cornerRadius))
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
