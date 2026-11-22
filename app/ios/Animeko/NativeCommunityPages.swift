import Foundation
import SwiftUI
import application

struct NativePeoplePage: View {
    let catalog: IosNativeCatalog
    let id: Int32
    let isCharacter: Bool
    @State private var handle: NativeScreenHandle<IosNativePeople>?
    @State private var state: IosPeopleState?
    @State private var showComments = false

    var body: some View {
        List {
            if let state, state.status == .ready {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        NativeActivityArtwork(url: state.artwork, symbol: "person")
                            .frame(width: 112, height: 144)
                            .clipShape(.rect(cornerRadius: 8))
                        Text(state.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        if !state.summary.isEmpty {
                            Text(state.summary).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 8)
                }
                if !state.info.isEmpty {
                    Section("Information") {
                        ForEach(Array(state.info.enumerated()), id: \.offset) { _, field in
                            LabeledContent(field.label, value: field.value)
                        }
                    }
                }
                if !state.actors.isEmpty {
                    Section("Voice Actors") {
                        ForEach(state.actors, id: \.id) { actor in
                            NavigationLink(value: NativeRoute.person(actor.id)) {
                                NativePersonLabel(person: actor)
                            }
                        }
                    }
                }
                Section {
                    Button("Comments", systemImage: "bubble.left.and.bubble.right") { showComments = true }
                }
                Section("Related Anime") {
                    ForEach(state.works, id: \.key) { work in
                        NavigationLink(value: NativeRoute.subject(work.subjectId)) {
                            HStack(spacing: 12) {
                                NativeActivityArtwork(url: work.artwork, symbol: "photo")
                                    .frame(width: 44, height: 62)
                                    .clipShape(.rect(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(work.title)
                                    if !work.role.isEmpty {
                                        Text(work.role).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if state.works.isEmpty {
                        NativeActivityFeedback(
                            status: state.worksStatus,
                            emptyTitle: "No Related Anime",
                            retry: { handle?.value.retryWorks() }
                        )
                    } else {
                        NativeActivityPagination(
                            canLoadMore: state.canLoadMore,
                            failed: state.appendFailed,
                            loadMore: { handle?.value.loadMore() },
                            retry: { handle?.value.retryWorks() }
                        )
                    }
                }
            } else {
                NativeActivityFeedback(status: state?.status, emptyTitle: "Person Unavailable", retry: { handle?.value.retry() })
            }
        }
        .navigationTitle(state?.title.isEmpty == false ? state?.title ?? "" : String(localized: "Details"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showComments) {
            NativeCommentsSheet(catalog: catalog, location: isCharacter ? .character(id) : .person(id)) {
                catalog.openPersonComments(id: id, character: isCharacter)
            }
        }
        .task {
            let current = handle ?? NativeScreenHandle(isCharacter ? catalog.openCharacter(id: id) : catalog.openPerson(id: id)) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }
}

struct NativePersonLabel: View {
    let person: IosPersonReference

    var body: some View {
        HStack(spacing: 12) {
            NativeActivityArtwork(url: person.artwork, symbol: "person")
                .frame(width: 38, height: 46)
                .clipShape(.rect(cornerRadius: 6))
            Text(person.name)
        }
    }
}

struct NativeSeriesPage: View {
    let catalog: IosNativeCatalog
    let subjectId: Int32
    @State private var handle: NativeScreenHandle<IosNativeSeries>?
    @State private var state: IosSeriesState?

    var body: some View {
        List {
            if let state, !state.nodes.isEmpty {
                ForEach(state.nodes, id: \.main.subject.subjectId) { node in
                    Section {
                        seriesLink(node.main, badge: node.number > 0 ? Text("Part \(Int(node.number))") : Text(platformName(node.main.platform)))
                        ForEach(node.branches, id: \.subject.subjectId) { branch in
                            seriesLink(branch, badge: Text(relationshipName(branch.relationship)))
                                .padding(.leading, 16)
                        }
                    }
                }
                if state.truncated {
                    Text("Some Related Anime Are Omitted").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                NativeActivityFeedback(
                    status: state?.status, emptyTitle: "No Related Anime",
                    retry: { handle?.value.retry() }
                )
            }
        }
        .navigationTitle("Series Connections")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openSeries(subjectId: subjectId)) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }

    private func seriesLink(_ entry: IosSeriesEntry, badge: Text) -> some View {
        NavigationLink(value: NativeRoute.subject(entry.subject.subjectId)) {
            HStack(spacing: 12) {
                NativeCover(subject: entry.subject).frame(width: 44, height: 62)
                VStack(alignment: .leading, spacing: 4) {
                    badge.font(.caption).foregroundStyle(.secondary)
                    Text(entry.subject.title)
                }
                if entry.selected {
                    Spacer()
                    Image(systemName: "location.circle.fill").accessibilityLabel("Current Anime")
                }
            }
        }
        .disabled(entry.selected)
    }

    private func platformName(_ platform: String?) -> LocalizedStringKey {
        switch platform {
        case "MOVIE": "Movie"
        case "OVA": "OVA"
        default: "Special"
        }
    }

    private func relationshipName(_ relationship: String?) -> LocalizedStringKey {
        switch relationship {
        case "SEQUEL": "Sequel"
        case "PREQUEL": "Prequel"
        case "DERIVED": "Spin-Off"
        case "SPECIAL": "Special"
        case "COMPILATION": "Compilation"
        case "MAIN_STORY": "Main Story"
        default: "Related Anime"
        }
    }
}

struct NativeCommentThreadPage: View {
    let catalog: IosNativeCatalog
    let location: NativeCommentLocation
    let commentId: String
    let replyId: String?
    var openEmbeddedThread: (() -> IosNativeCommentThread?)? = nil

    @State private var handle: NativeScreenHandle<IosNativeCommentThread>?
    @State private var state: IosCommentThreadState?
    @State private var draft = ""
    @State private var highlightedReply: String?
    @State private var report: CommentReportDraft?
    @State private var scrollAfterSending = false
    @State private var unavailable = false
    @FocusState private var replyFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let state, let root = state.root {
                    if state.status == .failed {
                        Button("Try Again") { handle?.value.refresh() }
                    }
                    Section {
                        row(root, canReply: state.canReply)
                    } header: {
                        if let subtitle = state.subtitle { Text(subtitle) }
                    }
                    Section("Replies") {
                        ForEach(state.replies, id: \.stableId) { reply in
                            row(reply, canReply: state.canReply)
                                .listRowBackground(highlightedReply == reply.stableId ? Color.accentColor.opacity(0.12) : Color.clear)
                                .id(reply.stableId)
                        }
                        if state.replies.isEmpty {
                            NativeActivityFeedback(
                                status: state.repliesStatus, emptyTitle: "No Replies",
                                retry: { handle?.value.retryReplies() }
                            )
                        } else {
                            NativeActivityPagination(
                                canLoadMore: state.canLoadMore,
                                failed: state.appendFailed,
                                loadMore: { handle?.value.loadMore() },
                                retry: { handle?.value.retryReplies() }
                            )
                        }
                    }
                } else {
                    NativeActivityFeedback(
                        status: unavailable ? .idle : state?.status,
                        emptyTitle: "Comment Unavailable",
                        retry: { handle?.value.refresh() }
                    )
                }
            }
            .refreshable { handle?.value.refresh() }
            .task(id: state?.focusReplyId) {
                guard let id = state?.focusReplyId else { return }
                highlightedReply = id
                proxy.scrollTo(id, anchor: .center)
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled {
                    highlightedReply = nil
                    handle?.value.acknowledgeFocus()
                }
            }
            .onChange(of: state?.replies.last?.stableId) { _, last in
                if scrollAfterSending, let last {
                    scrollAfterSending = false
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if state?.canReply == true { composer }
        }
        .navigationTitle("Comment Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if openEmbeddedThread == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: location.route) {
                        Label("Open Related Page", systemImage: "arrowshape.turn.up.right")
                    }
                }
            }
        }
        .sheet(item: $report) { value in
            NativeCommentReportSheet(author: value.author) { reason, detail in
                handle?.value.report(id: value.id, reason: reason, detail: detail)
                report = nil
            }
        }
        .alert(actionTitle, isPresented: Binding(
            get: { [.reported, .reportFailed, .sendFailed, .voteFailed].contains(state?.action ?? .idle) },
            set: { if !$0 { handle?.value.dismissAction() } }
        )) {
            Button("OK", role: .cancel) { handle?.value.dismissAction() }
        }
        .task {
            if handle == nil {
                let thread: IosNativeCommentThread
                if let openEmbeddedThread {
                    guard let embeddedThread = openEmbeddedThread() else {
                        unavailable = true
                        return
                    }
                    thread = embeddedThread
                } else {
                    switch location {
                    case .episode(let subject, let episode):
                        thread = catalog.openCommentThread(
                            host: .episode, firstId: subject, secondId: episode, commentId: commentId, replyId: replyId
                        )
                    case .person(let person):
                        thread = catalog.openCommentThread(
                            host: .person, firstId: person, secondId: 0, commentId: commentId, replyId: replyId
                        )
                    case .character(let character):
                        thread = catalog.openCommentThread(
                            host: .character, firstId: character, secondId: 0, commentId: commentId, replyId: replyId
                        )
                    }
                }
                handle = NativeScreenHandle(thread) { $0.close() }
            }
            if let current = handle {
                await observeNative(current.value.observe) { value in
                    state = value
                    if value.action == .sent {
                        draft = ""
                        replyFocused = false
                        scrollAfterSending = true
                        current.value.dismissAction()
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = state?.replyTargetName {
                HStack {
                    Text("Replying to \(name)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Reply Target", systemImage: "xmark.circle") { handle?.value.selectReply(id: nil) }
                        .labelStyle(.iconOnly)
                }
            }
            HStack(alignment: .bottom) {
                TextField("Write a Reply", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($replyFocused)
                    .disabled(state?.action == .sending)
                Button("Send Reply", systemImage: "arrow.up") { handle?.value.reply(text: draft) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var busy: Bool { state?.action == .sending || state?.action == .reporting }

    private var actionTitle: LocalizedStringKey {
        switch state?.action {
        case .reported: "Report Submitted"
        case .reportFailed: "Couldn’t Submit Report"
        case .voteFailed: "Couldn’t Save Vote"
        default: "Couldn’t Send Reply"
        }
    }

    private func row(_ comment: IosCommentRow, canReply: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(comment.author ?? String(localized: "Unknown Author")).font(.headline)
                Spacer()
                Text(nativeDate(comment.createdAtMillis), format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let target = comment.replyTo {
                Text("Replying to \(target)").font(.caption).foregroundStyle(.secondary)
            } else if comment.parentDeleted {
                Text("Replying to a Deleted Comment").font(.caption).foregroundStyle(.secondary)
            }
            Text(comment.body).textSelection(.enabled)
            if comment.readOnly {
                if let url = handle.flatMap({ URL(string: $0.value.originalUrl) }) {
                    Link("Open in Bangumi", destination: url).font(.footnote)
                }
            } else {
                HStack {
                    Button("Like", systemImage: comment.liked ? "hand.thumbsup.fill" : "hand.thumbsup") {
                        handle?.value.vote(id: comment.stableId, like: true)
                    }
                    .labelStyle(.iconOnly)
                    if comment.likes > 0 { Text(comment.likes, format: .number) }
                    Button("Dislike", systemImage: comment.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                        handle?.value.vote(id: comment.stableId, like: false)
                    }
                    .labelStyle(.iconOnly)
                    if canReply {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") {
                            handle?.value.selectReply(id: comment.stableId == state?.root?.stableId ? nil : comment.stableId)
                            replyFocused = true
                        }
                        .labelStyle(.iconOnly)
                        .disabled(busy)
                    }
                    Spacer()
                    Menu("Comment Actions", systemImage: "ellipsis") {
                        Button("Report Comment", role: .destructive) {
                            report = CommentReportDraft(id: comment.stableId, author: comment.author)
                        }
                        .disabled(busy)
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CommentReportDraft: Identifiable {
    let id: String
    let author: String?
}

struct NativeCommentsSheet: View {
    let catalog: IosNativeCatalog
    let location: NativeCommentLocation
    let open: () -> IosNativeComments

    @Environment(\.dismiss) private var dismiss
    @State private var handle: NativeScreenHandle<IosNativeComments>?
    @State private var state: IosCommentListState?
    @State private var draft = ""
    @State private var signIn = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if state?.originalCommentsUnavailable == true {
                    Label("Bangumi Comments Are Temporarily Unavailable", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let state, !state.comments.isEmpty {
                    ForEach(state.comments, id: \.stableId) { comment in
                        NavigationLink(value: comment.stableId) { commentPreview(comment) }
                    }
                    NativeActivityPagination(
                        canLoadMore: state.canLoadMore,
                        failed: state.appendFailed,
                        loadMore: { handle?.value.loadMore() },
                        retry: { handle?.value.retry() }
                    )
                } else {
                    NativeActivityFeedback(
                        status: state?.status,
                        emptyTitle: "No Comments",
                        retry: { handle?.value.retry() }
                    )
                }
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                NativeCommentThreadPage(
                    catalog: catalog,
                    location: location,
                    commentId: id,
                    replyId: nil,
                    openEmbeddedThread: { handle?.value.openThread(id: id) }
                )
            }
            .refreshable { handle?.value.refresh() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let url = handle.flatMap({ URL(string: $0.value.originalUrl) }) {
                    ToolbarItem(placement: .secondaryAction) {
                        Link("Open in Bangumi", destination: url)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let state {
                    HStack(alignment: .bottom) {
                        if state.signedIn {
                            TextField("Write a Comment", text: $draft, axis: .vertical)
                                .lineLimit(1...4)
                                .focused($composerFocused)
                                .disabled(state.action == .sending)
                            Button("Send Comment", systemImage: "arrow.up") { handle?.value.send(text: draft) }
                                .buttonStyle(.glassProminent)
                                .labelStyle(.iconOnly)
                                .disabled(state.action == .sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else {
                            Button("Sign In to Comment") { signIn = true }
                                .buttonStyle(.glass)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                }
            }
            .alert("Couldn’t Send Comment", isPresented: Binding(
                get: { state?.action == .sendFailed },
                set: { if !$0 { handle?.value.dismissAction() } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
        .sheet(isPresented: $signIn) {
            NativeAccountPage(catalog: catalog, entry: .email, hasUnreadNotifications: false)
        }
        .presentationDetents([.large])
        .task {
            let current = handle ?? NativeScreenHandle(open()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { value in
                state = value
                if value.action == .sent {
                    draft = ""
                    composerFocused = false
                    current.value.dismissAction()
                }
            }
        }
    }

    private func commentPreview(_ comment: IosCommentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(comment.author ?? String(localized: "Unknown Author")).font(.headline)
                Spacer()
                Text(nativeDate(comment.createdAtMillis), format: .dateTime.month().day())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(comment.body).lineLimit(4)
            if comment.replyCount == 1 {
                Text("1 Reply").font(.caption).foregroundStyle(.secondary)
            } else if comment.replyCount > 1 {
                Text("\(Int(comment.replyCount)) Replies").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NativeCommentReportSheet: View {
    let author: String?
    let submit: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "SPAM"
    @State private var detail = ""

    var body: some View {
        NavigationStack {
            Form {
                if let author { LabeledContent("Author", value: author) }
                Picker("Reason", selection: $reason) {
                    ForEach(["SPAM", "HARASSMENT", "SPOILER", "NSFW", "ILLEGAL", "OTHER"], id: \.self) { value in
                        Text(reportReason(value)).tag(value)
                    }
                }
                TextField("Additional Details", text: $detail, axis: .vertical).lineLimit(2...5)
            }
            .navigationTitle("Report Comment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { submit(reason, detail) }
                }
            }
        }
    }
}
