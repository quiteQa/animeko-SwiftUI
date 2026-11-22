import Foundation
import SwiftUI
import application

struct NativeNotificationsPage: View {
    let catalog: IosNativeCatalog
    let openRoute: (NativeRoute) -> Void
    let openAccount: (NativeAccountEntry) -> Void
    let openUpdateSettings: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var handle: NativeScreenHandle<IosNativeNotifications>?
    @State private var state: IosNotificationCenterState?
    @State private var interactions = false

    var body: some View {
        VStack(spacing: 12) {
            NavigationLink(value: NativeRoute.announcements) {
                HStack {
                    Image(systemName: "megaphone")
                    VStack(alignment: .leading) {
                        Text("Announcements").font(.headline)
                        if let headline = state?.latestAnnouncementTitle {
                            Text(headline).font(.footnote).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if state?.hasUnreadAnnouncements == true { NativeUnreadDot() }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("native.notifications.announcements")
            .padding(.horizontal)

            Picker("Notification Category", selection: $interactions) {
                tabLabel("Interactions", count: state?.interactions.unreadCount ?? 0).tag(true)
                tabLabel("Notices", count: state?.notices.unreadCount ?? 0).tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            TabView(selection: $interactions) {
                notices(state?.interactions, interactions: true).tag(true)
                notices(state?.notices, interactions: false).tag(false)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Mark All as Read", systemImage: "checkmark.circle") {
                    handle?.value.markAllRead(interactions: interactions)
                }
                .disabled((interactions ? state?.interactions.canMarkAllRead : state?.notices.canMarkAllRead) != true)
                NavigationLink(value: NativeRoute.notificationSettings) {
                    Label("Notification Settings", systemImage: "gearshape")
                }
            }
        }
        .alert("Couldn’t Mark Notifications as Read", isPresented: Binding(
            get: { state?.operationFailed == true },
            set: { if !$0 { handle?.value.dismissFailure() } }
        )) {
            Button("OK", role: .cancel) { handle?.value.dismissFailure() }
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openNotifications()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }

    private func notices(_ page: IosNoticePage?, interactions: Bool) -> some View {
        List {
            if let state, !state.accessLoading && !state.authorized {
                ContentUnavailableView {
                    Label("Sign In to View Notifications", systemImage: "bell.slash")
                } actions: {
                    Button("Sign In") { openAccount(.email) }
                }
                .listRowSeparator(.hidden)
            } else if state?.authorized == true, let page, !page.rows.isEmpty {
                if page.rows.contains(where: \.needsUpdate) {
                    Button("Check for Updates", systemImage: "info.circle", action: openUpdateSettings)
                }
                ForEach(page.rows, id: \.id) { row in
                    VStack(alignment: .leading) {
                        Button {
                            handle?.value.markRead(id: row.id)
                            open(row.destination, notificationId: row.id)
                        } label: {
                            NativeNoticeRowView(row: row)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if row.canReauthorize {
                            Button("Reauthorize Bangumi") {
                                handle?.value.markRead(id: row.id)
                                openAccount(.bangumi)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                NativeActivityPagination(
                    canLoadMore: page.canLoadMore,
                    failed: page.appendFailed,
                    loadMore: { handle?.value.loadMore(interactions: interactions) },
                    retry: { handle?.value.retry(interactions: interactions) }
                )
            } else {
                NativeActivityFeedback(
                    status: state?.accessLoading == false ? page?.status : nil,
                    emptyTitle: "No Notifications",
                    retry: { handle?.value.retry(interactions: interactions) }
                )
            }
        }
        .listStyle(.plain)
        .refreshable { handle?.value.refresh(interactions: interactions) }
    }

    private func tabLabel(_ key: LocalizedStringKey, count: Int32) -> Text {
        count > 0 ? Text("\(Text(key)) (\(count))") : Text(key)
    }

    private func open(_ destination: IosNoticeDestination, notificationId: String) {
        switch destination.kind {
        case .detail: openRoute(.notification(notificationId))
        case .account: openAccount(.profile)
        case .url:
            if let url = httpURL(destination.url) { openURL(url) }
        default:
            if let route = destination.nativeRoute { openRoute(route) }
        }
    }
}

struct NativeNotificationDetailPage: View {
    let catalog: IosNativeCatalog
    let id: String
    let openRoute: (NativeRoute) -> Void
    let openAccount: (NativeAccountEntry) -> Void
    let openUpdateSettings: () -> Void

    @State private var handle: NativeScreenHandle<IosNativeNotificationDetail>?
    @State private var state: IosNoticeDetailState?

    var body: some View {
        List {
            if let state, let row = state.row {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if let overline = row.overline { Text(overline).foregroundStyle(.secondary) }
                        Text(row.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text(nativeDate(row.createdAtMillis), format: .dateTime.month().day().hour().minute())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let body = state.body, !body.isEmpty {
                        Text(linkedText(body)).textSelection(.enabled)
                    }
                }
                if let report = state.report {
                    Section("Report Details") {
                        LabeledContent("Reason") { Text(reportReason(report.reason)) }
                        LabeledContent("Reported Content", value: report.target)
                        LabeledContent("Reported On") {
                            Text(nativeDate(report.reportedAtMillis), format: .dateTime.month().day().hour().minute())
                        }
                        LabeledContent("Reviewed On") {
                            Text(nativeDate(report.handledAtMillis), format: .dateTime.month().day().hour().minute())
                        }
                        LabeledContent("Outcome") {
                            Text(report.removed ? LocalizedStringKey("Content Removed") : LocalizedStringKey("Report Reviewed"))
                        }
                        if let snapshot = report.snapshot, !snapshot.isEmpty {
                            Text(snapshot).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if row.canReauthorize {
                    Button("Reauthorize Bangumi") { openAccount(.bangumi) }
                }
                if let target = state.destination, let title = state.actionTitle {
                    if let url = httpURL(target.url) {
                        Link(destination: url) { Label(title, systemImage: "arrow.up.right") }
                    } else if let route = target.nativeRoute {
                        Button(title) { openRoute(route) }
                    }
                }
                if row.needsUpdate {
                    Section {
                        Button("Check for Updates", action: openUpdateSettings)
                    } footer: {
                        Text("Some Notification Details May Be Unavailable")
                    }
                }
            } else {
                NativeActivityFeedback(
                    status: state?.status,
                    emptyTitle: "Notification Unavailable",
                    retry: { handle?.value.retry() }
                )
            }
        }
        .navigationTitle("Notification Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openNotification(id: id)) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }
}

struct NativeAnnouncementsPage: View {
    let catalog: IosNativeCatalog
    let openRoute: (NativeRoute) -> Void
    @State private var handle: NativeScreenHandle<IosNativeAnnouncements>?
    @State private var page: IosAnnouncementPage?

    var body: some View {
        List {
            if let page, !page.rows.isEmpty {
                ForEach(page.rows, id: \.id) { row in
                    Button {
                        handle?.value.markRead(id: row.id)
                        openRoute(.announcement(row.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(announcementCategory(row.tag)).font(.caption).foregroundStyle(.secondary)
                                if row.pinned { Image(systemName: "pin").accessibilityLabel("Pinned") }
                                Spacer()
                                NativeNoticeTime(millis: row.publishedAtMillis, relative: false)
                                    .font(.caption).foregroundStyle(.secondary)
                                if row.unread { NativeUnreadDot() }
                            }
                            Text(row.title).font(.headline)
                            Text(row.body).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityValue(row.unread ? Text("Unread") : Text(""))
                    }
                    .buttonStyle(.plain)
                }
                NativeActivityPagination(
                    canLoadMore: page.canLoadMore,
                    failed: page.appendFailed,
                    loadMore: { handle?.value.loadMore() },
                    retry: { handle?.value.retry() }
                )
            } else {
                NativeActivityFeedback(status: page?.status, emptyTitle: "No Announcements", retry: { handle?.value.retry() })
            }
        }
        .navigationTitle("Announcements")
        .refreshable { handle?.value.refresh() }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openAnnouncements()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { page = $0 }
        }
    }
}

struct NativeAnnouncementDetailPage: View {
    let catalog: IosNativeCatalog
    let id: String
    @State private var handle: NativeScreenHandle<IosNativeAnnouncementDetail>?
    @State private var state: IosAnnouncementDetailState?

    var body: some View {
        List {
            if let row = state?.row {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(announcementCategory(row.tag)).foregroundStyle(.secondary)
                        Text(row.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text(nativeDate(row.publishedAtMillis), format: .dateTime.year().month().day().hour().minute())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(linkedText(row.body)).textSelection(.enabled)
                    if let url = httpURL(row.url) {
                        Link(destination: url) { Label("View Details", systemImage: "arrow.up.right") }
                    }
                }
            } else {
                NativeActivityFeedback(
                    status: state?.status,
                    emptyTitle: "Announcement Unavailable",
                    retry: { handle?.value.retry() }
                )
            }
        }
        .navigationTitle("Announcement")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openAnnouncement(id: id)) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }
}

struct NativeNotificationSettingsPage: View {
    let catalog: IosNativeCatalog
    @State private var handle: NativeScreenHandle<IosNativeNotificationSettings>?
    @State private var preferences: IosNotificationPreferences?

    var body: some View {
        Form {
            if preferences != nil {
                Section("Notifications") {
                    Toggle("Replies to Comments", isOn: binding(\.commentReplies, .commentReplies))
                    Toggle("Report Results", isOn: binding(\.reportResults, .reportResults))
                    Toggle("Account Security", isOn: binding(\.accountSecurity, .accountSecurity))
                }
                Section("Announcements") {
                    Toggle("Show Announcement Badge", isOn: binding(\.announcementBadge, .announcementBadge))
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Notification Settings")
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openNotificationSettings()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { preferences = $0 }
        }
    }

    private func binding(_ key: KeyPath<IosNotificationPreferences, Bool>, _ field: IosNotificationPreference) -> Binding<Bool> {
        Binding(
            get: { preferences?[keyPath: key] ?? false },
            set: { handle?.value.update(preference: field, enabled: $0) }
        )
    }
}

private struct NativeNoticeRowView: View {
    let row: IosNoticeRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeActivityArtwork(url: row.imageUrl, symbol: row.symbol)
                .frame(width: 36, height: 36)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.overline ?? row.title).font(.headline).lineLimit(1)
                    Spacer()
                    NativeNoticeTime(millis: row.createdAtMillis, relative: true)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if row.unread { NativeUnreadDot() }
                }
                if row.overline != nil { Text(row.title).font(.subheadline) }
                if let supporting = row.supporting {
                    Text(supporting).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.unread ? Text("Unread") : Text(""))
    }
}

private struct NativeNoticeTime: View {
    let millis: Int64
    let relative: Bool

    var body: some View {
        let date = nativeDate(millis)
        let calendar = Calendar.current
        if relative && calendar.isDateInToday(date) {
            Text(date, style: .relative)
        } else if relative && calendar.isDateInYesterday(date) {
            Text("Yesterday")
        } else if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            Text(date, format: .dateTime.month().day())
        } else {
            Text(date, format: .dateTime.year().month().day())
        }
    }
}

struct NativeActivityArtwork: View {
    let url: String?
    let symbol: String

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                AsyncImage(url: httpURL(url)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: symbol).foregroundStyle(.secondary)
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

struct NativeActivityFeedback: View {
    let status: IosLoadStatus?
    let emptyTitle: LocalizedStringKey
    let retry: () -> Void

    var body: some View {
        switch status {
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Load Content", systemImage: "exclamationmark.circle")
            } actions: {
                Button("Try Again", action: retry)
            }
        case .ready, .idle:
            ContentUnavailableView(emptyTitle, systemImage: "tray")
        default:
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

struct NativeActivityPagination: View {
    let canLoadMore: Bool
    let failed: Bool
    let loadMore: () -> Void
    let retry: () -> Void

    var body: some View {
        if failed {
            Button("Try Again", action: retry)
        } else if canLoadMore {
            Button("Load More", action: loadMore)
        }
    }
}

func nativeDate(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1_000) }

private func httpURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http", url.host != nil else { return nil }
    return url
}

private func linkedText(_ text: String) -> AttributedString {
    var result = AttributedString(text)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
    for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let url = httpURL(match.url?.absoluteString), let range = Range(match.range, in: text),
              let start = AttributedString.Index(range.lowerBound, within: result),
              let end = AttributedString.Index(range.upperBound, within: result) else { continue }
        result[start..<end].link = url
    }
    return result
}

private func announcementCategory(_ tag: String) -> LocalizedStringKey {
    switch tag {
    case "maintenance": "Maintenance"
    case "release": "Release"
    case "community": "Community"
    default: "Announcement"
    }
}

func reportReason(_ reason: String) -> LocalizedStringKey {
    switch reason {
    case "SPAM": "Spam"
    case "HARASSMENT": "Harassment"
    case "SPOILER": "Spoiler"
    case "NSFW": "Explicit Content"
    case "ILLEGAL": "Illegal Content"
    default: "Other"
    }
}

private extension IosNoticeDestination {
    var nativeRoute: NativeRoute? {
        switch kind {
        case .episode: .episode(subjectId: firstId, episodeId: secondId)
        case .subject: .subject(firstId)
        case .person: .person(firstId)
        case .character: .character(firstId)
        case .episodeComment: commentId.map { .comment(.episode(firstId, secondId), id: $0, reply: replyId) }
        case .personComment: commentId.map { .comment(.person(firstId), id: $0, reply: replyId) }
        case .characterComment: commentId.map { .comment(.character(firstId), id: $0, reply: replyId) }
        default: nil
        }
    }
}
