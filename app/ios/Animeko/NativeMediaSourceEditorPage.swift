import Foundation
import SwiftUI
import UIKit
import application

struct NativeMediaSourceEditorPage: View {
    let catalog: IosNativeCatalog
    let kind: IosMediaSourceKind
    let instanceId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var handle: NativeScreenHandle<IosNativeMediaSourceEditor>?
    @State private var state: IosSourceEditorState?
    @State private var form = NativeSourceForm()
    @State private var originalForm: NativeSourceForm?
    @State private var draftVersion: Int32?
    @State private var appliedDocument = false
    @State private var document: NativeSourceEditorDocument?
    @State private var discard: NativeSourceDiscard?
    @State private var keyword = ""
    @State private var connectedForm: NativeSourceForm?
    @State private var searchedForm: NativeSourceForm?
    @State private var searchedKeyword = ""
    @State private var showEpisodes = false

    var body: some View {
        NavigationStack {
            Form {
                if let state, let editor = handle?.value, state.status == .ready {
                    if state.readOnly {
                        Label("Managed by Subscription", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                    sourceFields(editor)
                    toolsSection(editor)
                    previewSection(editor)
                    if document == nil, let error = state.error {
                        Label(sourceEditorError(error), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                        if error == .changed {
                            Button("Reload Configuration") { confirm(.reload) }
                        }
                    }
                } else if state?.status == .failed {
                    Label(sourceEditorError(state?.error), systemImage: "exclamationmark.circle")
                    Button("Try Again") { handle?.value.reload() }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(nativeMediaSourceKindTitle(kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state?.readOnly == true ? LocalizedStringKey("Done") : LocalizedStringKey("Cancel")) {
                        confirm(.close)
                    }
                    .disabled(state?.saving == true)
                }
                if state?.readOnly != true {
                    ToolbarItem(placement: .confirmationAction) {
                        if state?.saving == true {
                            ProgressView()
                        } else {
                            Button("Save") { handle?.value.save(fields: form.bridge) }
                                .disabled(state?.status != .ready || testing || !form.canSave)
                                .accessibilityIdentifier("native.sourceEditor.save")
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $showEpisodes) { NativeSourceEpisodePreview(state: $state) }
        }
        .interactiveDismissDisabled(hasChanges || state?.saving == true)
        .confirmationDialog(
            "Discard Configuration Changes?",
            isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }),
            titleVisibility: .visible,
            presenting: discard
        ) { action in
            Button("Discard Changes", role: .destructive) { perform(action) }
            Button("Keep Editing", role: .cancel) {}
        }
        .sheet(item: $document, onDismiss: { handle?.value.dismissError() }) { item in
            NativeSourceDocumentPage(document: item, state: $state, apply: applyDocument)
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openMediaSourceEditor(kind: kind, instanceId: instanceId)) {
                $0.close()
            }
            handle = current
            await observeNative(current.value.observe) { value in
                state = value
                if let fields = value.fields, draftVersion != value.draftVersion {
                    draftVersion = value.draftVersion
                    form = NativeSourceForm(fields)
                    if originalForm == nil { originalForm = form }
                    searchedForm = nil
                    connectedForm = nil
                }
                if value.saved { dismiss() }
            }
        }
    }

    private func sourceFields(_ editor: IosNativeMediaSourceEditor) -> some View {
        Group {
            Section("Source Details") {
                TextField("Source Name", text: $form.name)
                    .accessibilityIdentifier("native.sourceEditor.name")
                TextField("Description", text: $form.summary, axis: .vertical)
                    .lineLimit(1...4)
                address("Icon URL", value: $form.iconUrl, keyboard: .URL)
            }
            Section("Search Configuration") {
                if kind != .rss {
                    address("Base URL", value: $form.baseUrl, keyboard: .URL)
                }
                address("Search URL Template", value: $form.searchUrl, keyboard: .default)
                    .accessibilityIdentifier("native.sourceEditor.searchUrl")
                if kind == .jsonApi {
                    address("Episode List URL Template", value: $form.episodesUrl, keyboard: .default)
                    address("Playback URL Template", value: $form.playUrl, keyboard: .default)
                }
                if kind == .rss {
                    Toggle("Filter by Episode Number", isOn: $form.filterByEpisode)
                } else {
                    Toggle("Automatically Match Episodes", isOn: $form.autoMatch)
                }
            }
        }
        .disabled(state?.readOnly == true || state?.saving == true || testing)
        .onChange(of: form) { _, _ in editor.dismissError() }
    }

    private func toolsSection(_ editor: IosNativeMediaSourceEditor) -> some View {
        Section {
            Button("Advanced JSON", systemImage: "curlybraces") {
                if let text = editor.advancedJson(fields: form.bridge) {
                    editor.dismissError()
                    document = NativeSourceEditorDocument(mode: state?.readOnly == true ? .readOnly : .advanced, text: text)
                }
            }
            if state?.readOnly != true {
                Button("Import Configuration", systemImage: "square.and.arrow.down") {
                    editor.dismissError()
                    document = NativeSourceEditorDocument(mode: .importText, text: "")
                }
            }
            Button("Export Configuration", systemImage: "square.and.arrow.up") {
                if let text = editor.export(fields: form.bridge) {
                    editor.dismissError()
                    document = NativeSourceEditorDocument(mode: .exportText, text: text)
                }
            }
        }
        .disabled(state?.saving == true || testing)
    }

    @ViewBuilder
    private func previewSection(_ editor: IosNativeMediaSourceEditor) -> some View {
        Section("Test Configuration") {
            Button("Test Connection", systemImage: "network") {
                connectedForm = form
                editor.testConnection(fields: form.bridge)
            }
            .disabled(testing || (form.searchUrl.isEmpty && form.baseUrl.isEmpty))
            if connectedForm == form {
                switch state?.connection {
                case .loading: ProgressView()
                case .ready: Label("Connection Available", systemImage: "checkmark.circle")
                case .failed: Label("Connection Failed", systemImage: "exclamationmark.circle")
                default: EmptyView()
                }
            }
            TextField("Test Search Keyword", text: $keyword)
                .submitLabel(.search)
                .onSubmit { if canSearch { testSearch(editor) } }
            Button("Test Search", systemImage: "magnifyingglass") { testSearch(editor) }
                .disabled(!canSearch)
        }
        .disabled(state?.saving == true)

        if searchedForm == form, searchedKeyword == keyword.trimmingCharacters(in: .whitespacesAndNewlines), let state {
            Section("Search Results") {
                switch state.search {
                case .loading:
                    ProgressView()
                case .failed:
                    Label("Source Test Failed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                case .ready:
                    if state.results.isEmpty { Text("No Results").foregroundStyle(.secondary) }
                    ForEach(state.results, id: \.id) { result in
                        if state.canOpenResults {
                            Button {
                                editor.openPreview(index: result.id)
                                showEpisodes = true
                            } label: {
                                HStack {
                                    Text(result.title)
                                    Spacer()
                                    Image(systemName: "chevron.forward")
                                }
                            }
                            .disabled(testing)
                        } else {
                            Text(result.title)
                        }
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    private func address(_ title: LocalizedStringKey, value: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(title, text: value, axis: .vertical)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .font(.callout.monospaced())
            .lineLimit(1...3)
    }

    private var canSearch: Bool {
        !testing && !form.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var testing: Bool {
        state?.connection == .loading || state?.search == .loading || state?.browse == .loading
    }

    private var hasChanges: Bool {
        state?.readOnly != true && (appliedDocument || originalForm.map { $0 != form } == true)
    }

    private func testSearch(_ editor: IosNativeMediaSourceEditor) {
        searchedForm = form
        searchedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.testSearch(fields: form.bridge, keyword: keyword)
    }

    private func applyDocument(_ mode: NativeSourceEditorDocument.Mode, _ text: String) -> Bool {
        guard let editor = handle?.value else { return false }
        let applied = mode == .importText ? editor.importConfiguration(text: text) : editor.applyAdvancedJson(text: text)
        if applied { appliedDocument = true }
        return applied
    }

    private func confirm(_ action: NativeSourceDiscard) {
        if hasChanges { discard = action } else { perform(action) }
    }

    private func perform(_ action: NativeSourceDiscard) {
        switch action {
        case .close: dismiss()
        case .reload:
            originalForm = nil
            appliedDocument = false
            handle?.value.reload()
        }
    }
}

func nativeMediaSourceKindTitle(_ kind: IosMediaSourceKind) -> LocalizedStringKey {
    switch kind {
    case .selector: "CSS Selector"
    case .jsonApi: "JSON API"
    default: "RSS"
    }
}

private struct NativeSourceForm: Equatable {
    var name = ""
    var summary = ""
    var iconUrl = ""
    var baseUrl = ""
    var searchUrl = ""
    var episodesUrl = ""
    var playUrl = ""
    var autoMatch = true
    var filterByEpisode = true

    init() {}

    init(_ fields: IosMediaSourceFields) {
        name = fields.name
        summary = fields.summary
        iconUrl = fields.iconUrl
        baseUrl = fields.baseUrl
        searchUrl = fields.searchUrl
        episodesUrl = fields.episodesUrl
        playUrl = fields.playUrl
        autoMatch = fields.autoMatch
        filterByEpisode = fields.filterByEpisode
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var bridge: IosMediaSourceFields {
        IosMediaSourceFields(
            name: name, summary: summary, iconUrl: iconUrl, baseUrl: baseUrl, searchUrl: searchUrl,
            episodesUrl: episodesUrl, playUrl: playUrl, autoMatch: autoMatch, filterByEpisode: filterByEpisode
        )
    }
}

private enum NativeSourceDiscard { case close, reload }

private struct NativeSourceEditorDocument: Identifiable {
    enum Mode { case advanced, readOnly, importText, exportText }

    let id = UUID()
    let mode: Mode
    let text: String
}

private struct NativeSourceDocumentPage: View {
    let document: NativeSourceEditorDocument
    @Binding var state: IosSourceEditorState?
    let apply: (NativeSourceEditorDocument.Mode, String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Group {
                if editable {
                    VStack(alignment: .leading, spacing: 0) {
                        if let issue = state?.error {
                            Label(sourceEditorError(issue), systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                                .padding()
                        }
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel(title)
                            .accessibilityIdentifier("native.sourceEditor.json")
                    }
                    .padding(.horizontal)
                } else {
                    ScrollView {
                        Text(document.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editable ? LocalizedStringKey("Cancel") : LocalizedStringKey("Done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if document.mode == .importText {
                        PasteButton(payloadType: String.self) { items in
                            if let item = items.first { text = item }
                        }
                    }
                    if editable {
                        Button(document.mode == .importText ? LocalizedStringKey("Import") : LocalizedStringKey("Apply")) {
                            if apply(document.mode, text) { dismiss() }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else if document.mode == .exportText {
                        ShareLink(item: document.text)
                    }
                }
            }
        }
        .onAppear { text = document.text }
    }

    private var editable: Bool { document.mode == .importText || document.mode == .advanced }

    private var title: LocalizedStringKey {
        switch document.mode {
        case .importText: "Import Configuration"
        case .exportText: "Export Configuration"
        default: "Advanced JSON"
        }
    }
}

private struct NativeSourceEpisodePreview: View {
    @Binding var state: IosSourceEditorState?

    var body: some View {
        List {
            if let state {
                switch state.browse {
                case .loading: ProgressView()
                case .failed: Label("Source Test Failed", systemImage: "exclamationmark.circle")
                case .ready:
                    if state.lines.isEmpty { Text("No Episodes").foregroundStyle(.secondary) }
                    ForEach(state.lines, id: \.index) { line in
                        Section {
                            ForEach(Array(line.episodes.enumerated()), id: \.offset) { _, episode in Text(episode) }
                        } header: {
                            if let title = line.title, !title.isEmpty {
                                Text(title)
                            } else {
                                Text("Line \(Int(line.index) + 1)")
                            }
                        }
                    }
                default: EmptyView()
                }
            }
        }
        .navigationTitle(state?.browsedTitle ?? String(localized: "Episodes"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func sourceEditorError(_ error: IosSourceEditorError?) -> LocalizedStringKey {
    switch error {
    case .missing: "Media Source Unavailable"
    case .changed: "Configuration Changed Elsewhere"
    case .emptyImport: "No Configuration to Import"
    case .multipleImport: "Import One Media Source at a Time"
    case .wrongKind: "Configuration Is for a Different Source Type"
    case .unsupportedVersion: "Requires a Newer App Version"
    case .saveFailed: "Couldn’t Save Configuration"
    default: "Invalid Source Configuration"
    }
}
