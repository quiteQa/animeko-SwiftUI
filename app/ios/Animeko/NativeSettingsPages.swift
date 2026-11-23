import Foundation
import SwiftUI
import UIKit
import application

private enum NativeSettingsRoute: Hashable {
    case playback, notifications, mediaSources, about
}

struct NativeSettingsPage: View {
    let catalog: IosNativeCatalog
    @Binding var appearance: IosAppearance
    let openClassicInterface: () -> Void
    let openUpdateSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: IosSettingsState?

    var body: some View {
        let settings = catalog.openSettings()
        NavigationStack {
            Form {
                Section {
                    NavigationLink(value: NativeSettingsRoute.playback) {
                        Label("Playback", systemImage: "play.rectangle")
                    }
                    .accessibilityIdentifier("native.settings.playback")
                    NavigationLink(value: NativeSettingsRoute.mediaSources) {
                        Label("Media Sources", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .accessibilityIdentifier("native.settings.sources")
                    NavigationLink(value: NativeSettingsRoute.notifications) {
                        Label("Notifications", systemImage: "bell")
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag(IosAppearance.system)
                        Text("Light").tag(IosAppearance.light)
                        Text("Dark").tag(IosAppearance.dark)
                    }
                    if let state {
                        Picker("Start Page", selection: Binding(
                            get: { state.initialTab }, set: { settings.setInitialTab(value: $0) }
                        )) {
                            Text("Explore").tag(IosInitialTab.explore)
                            Text("Collection").tag(IosInitialTab.collection)
                            Text("Downloads").tag(IosInitialTab.downloads)
                        }
                        Toggle("Prefer Original Titles", isOn: Binding(
                            get: { state.originalTitles }, set: { settings.setOriginalTitles(enabled: $0) }
                        ))
                        Toggle("Show Episode Images", isOn: Binding(
                            get: { state.episodeImages }, set: { settings.setEpisodeImages(enabled: $0) }
                        ))
                    }
                }
                if let state {
                    Section("Search") {
                        Toggle("Hide Completed and Dropped Anime", isOn: Binding(
                            get: { state.hideCompletedSearch }, set: { settings.setHideCompletedSearch(enabled: $0) }
                        ))
                        Picker("Sensitive Content", selection: Binding(
                            get: { state.sensitiveContent }, set: { settings.setSensitiveContent(value: $0) }
                        )) {
                            Text("Hide").tag(IosSensitiveContent.hide)
                            Text("Blur Covers").tag(IosSensitiveContent.blur)
                            Text("Show").tag(IosSensitiveContent.show)
                        }
                    }
                }
                Section {
                    NavigationLink(value: NativeSettingsRoute.about) {
                        Label("About Animeko", systemImage: "info.circle")
                    }
                }
                Section {
                    Button("Open Full App", action: openClassicInterface)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: NativeSettingsRoute.self) { route in
                switch route {
                case .playback:
                    NativePlaybackSettingsPage(settings: settings)
                case .mediaSources:
                    NativeMediaSourcesPage(catalog: catalog)
                case .notifications:
                    NativeNotificationSettingsPage(catalog: catalog)
                case .about:
                    NativeAboutPage(openUpdateSettings: openUpdateSettings)
                }
            }
        }
        .presentationDetents([.large])
        .task { await observeNative(settings.observe) { state = $0 } }
    }
}

private struct NativePlaybackSettingsPage: View {
    let settings: IosNativeSettings
    @State private var state: IosSettingsState?

    var body: some View {
        Form {
            if let state {
                Section("Playback") {
                    Toggle("Automatically Play Next Episode", isOn: Binding(
                        get: { state.autoPlayNext }, set: { settings.setAutoPlayNext(enabled: $0) }
                    ))
                    Toggle("Automatically Mark as Watched", isOn: Binding(
                        get: { state.autoMarkWatched }, set: { settings.setAutoMarkWatched(enabled: $0) }
                    ))
                    Toggle("Skip Opening and Ending", isOn: Binding(
                        get: { state.autoSkipOpeningAndEnding },
                        set: { settings.setAutoSkipOpeningAndEnding(enabled: $0) }
                    ))
                    Toggle("Automatic Picture in Picture", isOn: Binding(
                        get: { state.autoPictureInPicture }, set: { settings.setAutoPictureInPicture(enabled: $0) }
                    ))
                }
                Section("Source Selection") {
                    Toggle("Quickly Select Online Sources", isOn: Binding(
                        get: { state.fastSelectWeb }, set: { settings.setFastSelectWeb(enabled: $0) }
                    ))
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .task { await observeNative(settings.observe) { state = $0 } }
    }
}

private struct NativeAboutPage: View {
    let openUpdateSettings: () -> Void

    var body: some View {
        Form {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            Button("Check for Updates", action: openUpdateSettings)
            if let url = URL(string: "https://github.com/open-ani/ani") {
                Link("Source Code", destination: url)
            }
        }
        .navigationTitle("About Animeko")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum NativeSourceRemoval {
    case source(String), subscription(String)
}

private struct NativeSourceExport: Identifiable {
    let id = UUID()
    let text: String
}

private struct NativeSourceEditorRoute: Identifiable {
    let id = UUID()
    let kind: IosMediaSourceKind
    let instanceId: String?
}

private struct NativeMediaSourcesPage: View {
    let catalog: IosNativeCatalog

    @State private var handle: NativeScreenHandle<IosNativeMediaSources>?
    @State private var state: IosMediaSourceState?
    @State private var addPresented = false
    @State private var pendingURL = ""
    @State private var removal: NativeSourceRemoval?
    @State private var export: NativeSourceExport?
    @State private var editorRoute: NativeSourceEditorRoute?

    var body: some View {
        List {
            if let state, let sources = handle?.value {
                if state.failed {
                    Label("Couldn’t Complete the Action", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
                Section("Subscriptions") {
                    if state.subscriptions.isEmpty {
                        Text("No Subscriptions").foregroundStyle(.secondary)
                    }
                    ForEach(state.subscriptions, id: \.id) { subscription in
                        subscriptionGroup(subscription, sources: sources)
                    }
                }
                Section("Local Sources") {
                    if state.localSources.isEmpty {
                        Text("No Local Sources").foregroundStyle(.secondary)
                    }
                    ForEach(state.localSources, id: \.id) { source in
                        sourceRow(source, sources: sources, supportsRemoval: true)
                    }
                    .onMove { from, to in
                        var ids = state.localSources.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        sources.reorderLocalSources(ids: ids)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .disabled(state?.working == true)
        .navigationTitle("Media Sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state?.working == true {
                ProgressView()
            } else {
                Menu("Media Source Actions", systemImage: "ellipsis") {
                    Menu("Add Custom Source", systemImage: "plus") {
                        ForEach([IosMediaSourceKind.selector, .jsonApi, .rss], id: \.self) { kind in
                            Button(nativeMediaSourceKindTitle(kind)) {
                                editorRoute = NativeSourceEditorRoute(kind: kind, instanceId: nil)
                            }
                        }
                    }
                    Button("Add Subscription", systemImage: "plus") {
                        pendingURL = ""
                        addPresented = true
                    }
                    Button("Refresh Subscriptions", systemImage: "arrow.clockwise") { handle?.value.refreshAll() }
                        .disabled(state?.subscriptions.contains(where: \.enabled) != true)
                }
                .accessibilityIdentifier("native.sources.actions")
                .disabled(state == nil)
                EditButton().disabled((state?.localSources.count ?? 0) < 2)
            }
        }
        .alert("Add Subscription", isPresented: $addPresented) {
            TextField("Subscription URL", text: $pendingURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { handle?.value.addSubscription(url: pendingURL) }
                .disabled(!hasValidSubscriptionURL)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove Media Source?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible,
            presenting: removal
        ) { target in
            Button("Remove", role: .destructive) { remove(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            if case .subscription = target {
                Text("This removes the subscription and its media sources.")
            }
        }
        .sheet(item: $editorRoute) { route in
            NativeMediaSourceEditorPage(catalog: catalog, kind: route.kind, instanceId: route.instanceId)
        }
        .sheet(item: $export) { value in
            NavigationStack {
                List {
                    ShareLink(item: value.text) { Label("Share Subscription", systemImage: "square.and.arrow.up") }
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = value.text
                        export = nil
                    }
                }
                .navigationTitle("Export Subscription")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { export = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openMediaSources()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { value in
                state = value
                if let text = value.exportText {
                    export = NativeSourceExport(text: text)
                    current.value.clearExport()
                }
            }
        }
    }

    private var hasValidSubscriptionURL: Bool {
        guard let url = URLComponents(string: pendingURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
        return (scheme == "https" || scheme == "http") && !host.isEmpty
    }

    private func subscriptionGroup(_ subscription: IosMediaSourceSubscription, sources: IosNativeMediaSources) -> some View {
        DisclosureGroup {
            Toggle("Enable Subscription", isOn: Binding(
                get: { subscription.enabled },
                set: { sources.setSubscriptionEnabled(id: subscription.id, enabled: $0) }
            ))
            Text(subscription.url).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            if let summary = subscription.summary, !summary.isEmpty {
                Text(summary).font(.subheadline)
            }
            ForEach(subscription.sources, id: \.id) { source in
                sourceRow(source, sources: sources, supportsRemoval: false)
            }
            Menu("Manage Subscription", systemImage: "ellipsis.circle") {
                Button("Refresh", systemImage: "arrow.clockwise") { sources.refresh(id: subscription.id) }
                    .disabled(!subscription.enabled)
                Button("Export Subscription", systemImage: "square.and.arrow.up") {
                    sources.exportSubscription(id: subscription.id)
                }
                .disabled(subscription.sources.isEmpty)
                Button(role: .destructive) {
                    removal = .subscription(subscription.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(subscription.title)
                if subscription.refreshFailed {
                    Text(subscription.requiresNewerApp ? "Requires a Newer App Version" : "Refresh Failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if subscription.updatedAtMillis > 0 {
                    Text(Date(timeIntervalSince1970: Double(subscription.updatedAtMillis) / 1000), style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sourceRow(
        _ source: IosMediaSource,
        sources: IosNativeMediaSources,
        supportsRemoval: Bool
    ) -> some View {
        Toggle(isOn: Binding(get: { source.enabled }, set: { sources.setSourceEnabled(id: source.id, enabled: $0) })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                switch source.connection {
                case .ready:
                    Text("Connection Available").font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Text("Connection Failed").font(.caption).foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }
        }
        .contextMenu {
            if let kind = source.editorKind {
                Button(
                    source.managedBySubscription ? LocalizedStringKey("View Configuration") : LocalizedStringKey("Edit Configuration"),
                    systemImage: source.managedBySubscription ? "doc.text" : "pencil"
                ) {
                    editorRoute = NativeSourceEditorRoute(kind: kind, instanceId: source.id)
                }
            }
            Button("Test Connection", systemImage: "network") { sources.testSource(id: source.id) }
            if supportsRemoval {
                Button(role: .destructive) {
                    removal = .source(source.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    private func remove(_ target: NativeSourceRemoval) {
        switch target {
        case .source(let id): handle?.value.deleteLocalSource(id: id)
        case .subscription(let id): handle?.value.deleteSubscription(id: id)
        }
    }
}
