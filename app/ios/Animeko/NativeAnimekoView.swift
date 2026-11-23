import Foundation
import SwiftUI
import application

enum NativeTab: String {
    case explore, collection, downloads, search
}

enum NativeRoute: Hashable, Codable {
    case subject(Int32)
    case subjectDownloads(Int32)
    case episode(subjectId: Int32, episodeId: Int32)
    case ranking
    case schedule
    case notifications
    case notification(String)
    case announcements
    case announcement(String)
    case notificationSettings
    case history
    case historySync
    case person(Int32)
    case character(Int32)
    case series(Int32)
    case comment(NativeCommentLocation, id: String, reply: String?)
}

enum NativeCommentLocation: Hashable, Codable {
    case episode(Int32, Int32)
    case person(Int32)
    case character(Int32)

    var route: NativeRoute {
        switch self {
        case .episode(let subject, let episode): .episode(subjectId: subject, episodeId: episode)
        case .person(let id): .person(id)
        case .character(let id): .character(id)
        }
    }
}

enum NativeAccountEntry: Hashable {
    case profile, email, bangumi, qr(String)
}

private struct NativeNavigationRequest: Equatable {
    let id = UUID()
    let tab: NativeTab
    let route: NativeRoute
}

struct NativeAnimekoView: View {
    let catalog: IosNativeCatalog
    @Binding var qrLoginRequest: String?
    let openClassicInterface: () -> Void
    let openUpdateSettings: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("native.selectedTab") private var storedTab: String?
    @State private var appearance: IosAppearance = .system
    @State private var initialTab: NativeTab = .explore
    @State private var searchText = ""
    @State private var submittedSearch = ""
    @State private var sheet: NativeRootSheet?
    @State private var requestedRoute: NativeNavigationRequest?
    @State private var hasUnreadNotifications = false

    var body: some View {
        TabView(selection: selectedTab) {
            Tab("Explore", systemImage: "safari", value: .explore) {
                stack(.explore) { NativeExplorePage(catalog: catalog) }
            }
            Tab("Collection", systemImage: "star", value: .collection) {
                stack(.collection) { NativeCollectionPage(catalog: catalog) }
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                stack(.downloads) { NativeDownloadsPage(catalog: catalog) }
            }
            Tab(value: .search, role: .search) {
                stack(.search) { NativeSearchPage(catalog: catalog, query: submittedSearch) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .searchable(text: $searchText, prompt: "Search Anime")
        .onSubmit(of: .search) { submittedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
        .onChange(of: searchText) { _, text in
            if text.isEmpty { submittedSearch = "" }
        }
        .preferredColorScheme(colorScheme)
        .sheet(item: $sheet) { item in
            switch item {
            case .settings:
                NativeSettingsPage(
                    catalog: catalog,
                    appearance: Binding(
                        get: { appearance },
                        set: { value in
                            appearance = value
                            catalog.setAppearance(appearance: value)
                        }
                    ),
                    openClassicInterface: openClassicInterface,
                    openUpdateSettings: openUpdateSettings
                )
            case .account(let entry):
                NativeAccountPage(
                    catalog: catalog,
                    entry: entry,
                    hasUnreadNotifications: hasUnreadNotifications,
                    openActivity: openActivity
                )
            }
        }
        .onChange(of: qrLoginRequest, initial: true) { _, requestId in
            if let requestId {
                sheet = .account(.qr(requestId))
                qrLoginRequest = nil
            }
        }
        .task {
            await observeNative(catalog.observePreferences) { preferences in
                appearance = preferences.appearance
                switch preferences.initialTab {
                case .collection: initialTab = .collection
                case .downloads: initialTab = .downloads
                default: initialTab = .explore
                }
            }
        }
        .task {
            await observeNative(catalog.observeNotificationBadge) { hasUnreadNotifications = $0.hasUnread }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            catalog.setNotificationForeground(foreground: phase != .background)
        }
        .onDisappear { catalog.setNotificationForeground(foreground: false) }
    }

    private var selectedTab: Binding<NativeTab> {
        Binding(
            get: { storedTab.flatMap(NativeTab.init(rawValue:)) ?? initialTab },
            set: { storedTab = $0.rawValue }
        )
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case .light: .light
        case .dark: .dark
        default: nil
        }
    }

    private func openActivity(_ route: NativeRoute) {
        sheet = nil
        requestedRoute = NativeNavigationRequest(tab: selectedTab.wrappedValue, route: route)
    }

    private func stack<Content: View>(_ tab: NativeTab, @ViewBuilder content: () -> Content) -> some View {
        NativeTabStack(
            tab: tab,
            catalog: catalog,
            request: requestedRoute,
            openAccount: { sheet = .account($0) },
            openUpdateSettings: openUpdateSettings
        ) {
            content()
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            sheet = .account(.profile)
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .overlay(alignment: .topTrailing) {
                                    if hasUnreadNotifications { NativeUnreadDot() }
                                }
                        }
                        .accessibilityLabel("Account")
                        .accessibilityIdentifier("native.account")
                        Button("Settings", systemImage: "gearshape") { sheet = .settings }
                            .accessibilityIdentifier("native.settings")
                    }
                }
        }
    }
}

private enum NativeRootSheet: Hashable, Identifiable {
    case settings
    case account(NativeAccountEntry)

    var id: Self { self }
}

private struct NativeTabStack<Content: View>: View {
    let tab: NativeTab
    let catalog: IosNativeCatalog
    let request: NativeNavigationRequest?
    let openAccount: (NativeAccountEntry) -> Void
    let openUpdateSettings: () -> Void
    let content: Content

    @SceneStorage private var savedPath: Data?
    @State private var path: [NativeRoute] = []

    init(
        tab: NativeTab,
        catalog: IosNativeCatalog,
        request: NativeNavigationRequest?,
        openAccount: @escaping (NativeAccountEntry) -> Void,
        openUpdateSettings: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.tab = tab
        self.catalog = catalog
        self.request = request
        self.openAccount = openAccount
        self.openUpdateSettings = openUpdateSettings
        self.content = content()
        _savedPath = SceneStorage("native.path.\(tab.rawValue)")
    }

    var body: some View {
        NavigationStack(path: $path) {
            content.navigationDestination(for: NativeRoute.self) { route in
                switch route {
                case .subject(let subjectId):
                    NativeSubjectPage(catalog: catalog, subjectId: subjectId, signIn: { openAccount(.email) })
                case .subjectDownloads(let subjectId):
                    NativeSubjectDownloadsPage(catalog: catalog, subjectId: subjectId)
                case .episode(let subjectId, let episodeId):
                    NativePlaybackPage(catalog: catalog, subjectId: subjectId, episodeId: episodeId)
                case .ranking:
                    NativeRankingPage(catalog: catalog)
                case .schedule:
                    NativeSchedulePage(catalog: catalog)
                case .notifications:
                    NativeNotificationsPage(
                        catalog: catalog,
                        openRoute: { path.append($0) },
                        openAccount: openAccount,
                        openUpdateSettings: openUpdateSettings
                    )
                case .notification(let id):
                    NativeNotificationDetailPage(
                        catalog: catalog,
                        id: id,
                        openRoute: { path.append($0) },
                        openAccount: openAccount,
                        openUpdateSettings: openUpdateSettings
                    )
                case .announcements:
                    NativeAnnouncementsPage(catalog: catalog, openRoute: { path.append($0) })
                case .announcement(let id):
                    NativeAnnouncementDetailPage(catalog: catalog, id: id)
                case .notificationSettings:
                    NativeNotificationSettingsPage(catalog: catalog)
                case .history:
                    NativePlaybackHistoryPage(catalog: catalog, showPending: false)
                case .historySync:
                    NativePlaybackHistoryPage(catalog: catalog, showPending: true)
                case .person(let id):
                    NativePeoplePage(catalog: catalog, id: id, isCharacter: false)
                case .character(let id):
                    NativePeoplePage(catalog: catalog, id: id, isCharacter: true)
                case .series(let id):
                    NativeSeriesPage(catalog: catalog, subjectId: id)
                case .comment(let location, let id, let reply):
                    NativeCommentThreadPage(catalog: catalog, location: location, commentId: id, replyId: reply)
                }
            }
        }
        .onChange(of: request) { _, value in
            if let value, value.tab == tab { path.append(value.route) }
        }
        .onChange(of: path) { _, newPath in savedPath = try? JSONEncoder().encode(newPath) }
        .task {
            if path.isEmpty, let savedPath, let restored = try? JSONDecoder().decode([NativeRoute].self, from: savedPath) {
                path = restored
            }
        }
    }
}

struct NativeUnreadDot: View {
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// The owner lives with the navigation entry, while individual SwiftUI tasks may stop when covered.
final class NativeScreenHandle<Value> {
    let value: Value
    private let close: (Value) -> Void

    init(_ value: Value, close: @escaping (Value) -> Void) {
        self.value = value
        self.close = close
    }

    deinit {
        let value = self.value
        let close = self.close
        Task { @MainActor in close(value) }
    }
}

@MainActor
func observeNative<Value>(
    _ start: (@escaping (Value) -> Void) -> IosObservation,
    onValue: (Value) -> Void
) async {
    let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let observation = start { value in
        continuation.yield(value)
    }
    defer {
        observation.cancel()
        continuation.finish()
    }
    for await value in stream {
        guard !Task.isCancelled else { return }
        onValue(value)
    }
}
