import AVFoundation
import Foundation
import SwiftUI
import UIKit
import VisionKit
import application

private enum NativeAccountRoute: Hashable {
    case email
    case oauth(String, String)
    case bangumiMerge
    case scan
    case confirm(String)
}

struct NativeAccountPage: View {
    let catalog: IosNativeCatalog
    let hasUnreadNotifications: Bool
    let openActivity: ((NativeRoute) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var path: [NativeAccountRoute]
    @State private var handle: NativeScreenHandle<IosNativeAccount>?
    @State private var state: IosAccountState?
    @State private var confirmSignOut = false

    init(
        catalog: IosNativeCatalog,
        entry: NativeAccountEntry,
        hasUnreadNotifications: Bool,
        openActivity: ((NativeRoute) -> Void)? = nil
    ) {
        self.catalog = catalog
        self.hasUnreadNotifications = hasUnreadNotifications
        self.openActivity = openActivity
        switch entry {
        case .profile: _path = State(initialValue: [])
        case .email: _path = State(initialValue: [.email])
        case .bangumi: _path = State(initialValue: [.oauth("bangumi", "Bangumi")])
        case .qr(let id): _path = State(initialValue: [.confirm(id)])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                if let openActivity {
                    Section {
                        Button {
                            openActivity(.notifications)
                        } label: {
                            HStack {
                                Label("Notifications", systemImage: "bell")
                                Spacer()
                                if hasUnreadNotifications { NativeUnreadDot() }
                            }
                        }
                        .accessibilityIdentifier("native.account.notifications")
                        Button {
                            openActivity(.history)
                        } label: {
                            Label("Playback History", systemImage: "clock.arrow.circlepath")
                        }
                        .accessibilityIdentifier("native.account.history")
                    }
                }
                if let state, state.isSignedIn {
                    if let nickname = state.nickname {
                        LabeledContent("Nickname", value: nickname)
                    }
                    if let email = state.email {
                        LabeledContent("Email", value: email)
                    }
                    NavigationLink("Manage Email", value: NativeAccountRoute.email)
                    if let bangumiUsername = state.bangumiUsername, !bangumiUsername.isEmpty {
                        LabeledContent("Bangumi", value: bangumiUsername)
                        NavigationLink("Merge Bangumi Collections", value: NativeAccountRoute.bangumiMerge)
                    } else {
                        NavigationLink("Link Bangumi", value: NativeAccountRoute.oauth("bangumi", "Bangumi"))
                    }
                    NavigationLink("Scan Sign-In Code", value: NativeAccountRoute.scan)
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } else if state != nil {
                    NavigationLink("Sign In", value: NativeAccountRoute.email)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: NativeAccountRoute.self) { route in
                switch route {
                case .email:
                    NativeEmailPage(catalog: catalog)
                case .oauth(let id, let name):
                    NativeOAuthPage(catalog: catalog, providerId: id, providerName: name)
                case .bangumiMerge:
                    NativeBangumiMergePage(catalog: catalog)
                case .scan:
                    NativeQrScanner(catalog: catalog) { requestId in
                        if path.last == .scan {
                            path[path.count - 1] = .confirm(requestId)
                        }
                    }
                case .confirm(let id):
                    NativeQrConfirmationPage(catalog: catalog, requestId: id)
                }
            }
            .confirmationDialog("Sign Out?", isPresented: $confirmSignOut) {
                Button("Sign Out", role: .destructive) { handle?.value.signOut() }
            }
        }
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openAccount()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }
}

private struct NativeEmailPage: View {
    let catalog: IosNativeCatalog

    @Environment(\.dismiss) private var dismiss
    @State private var handle: NativeScreenHandle<IosNativeEmailSignIn>?
    @State private var state: IosEmailSignInState?
    @State private var email = ""
    @State private var code = ""

    var body: some View {
        Form {
            if state?.stage == .code {
                Section("Verification Code") {
                    Text(state?.email ?? email)
                        .foregroundStyle(.secondary)
                    TextField("Six-Digit Code", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .onChange(of: code) { _, value in
                            code = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        }
                    Button("Verify") { handle?.value.submitCode(code: code) }
                        .disabled(code.count != 6)
                }
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Button("Resend Code") { handle?.value.sendCode(email: email) }
                            .disabled(Double(state?.resendAtMillis ?? 0) > context.date.timeIntervalSince1970 * 1000)
                    }
                    Button("Edit Email") {
                        code = ""
                        handle?.value.editEmail()
                    }
                }
            } else if let state {
                Section("Email") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    Button("Send Code") { handle?.value.sendCode(email: email) }
                        .disabled(!email.contains("@") || !email.contains("."))
                }
                if !state.providers.isEmpty {
                    Section("Linked Accounts") {
                        ForEach(state.providers, id: \.id) { provider in
                            NavigationLink(provider.name, value: NativeAccountRoute.oauth(provider.id, provider.name))
                        }
                    }
                }
            } else {
                ProgressView()
            }
            if state?.failed == true {
                Text("Verification Failed. Try Again.")
                    .foregroundStyle(.red)
            }
        }
        .disabled(state?.isBusy == true)
        .overlay { if state?.isBusy == true { ProgressView() } }
        .navigationTitle(state?.canBindEmail == true ? LocalizedStringKey("Manage Email") : LocalizedStringKey("Sign In"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openEmailSignIn()) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { value in
                state = value
                if value.stage == .complete { dismiss() }
            }
        }
    }
}

private struct NativeOAuthPage: View {
    let catalog: IosNativeCatalog
    let providerId: String
    let providerName: String

    @State private var handle: NativeScreenHandle<IosNativeOAuth>?
    @State private var status: IosLoadStatus?

    var body: some View {
        Form {
            switch status {
            case .ready:
                Label("Authorized", systemImage: "checkmark.circle")
            case .loading:
                ProgressView("Waiting for Authorization")
                Button("Cancel", role: .cancel) { handle?.value.cancel() }
            case .idle, .failed:
                if status == .failed {
                    Label("Authorization Failed", systemImage: "exclamationmark.circle")
                }
                Button("Authorize in Browser") { handle?.value.authorize() }
            default:
                ProgressView()
            }
        }
        .navigationTitle(providerName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if handle == nil, let authorization = catalog.openOAuth(providerId: providerId) {
                handle = NativeScreenHandle(authorization) { $0.close() }
            }
            if let handle {
                await observeNative(handle.value.observe) { status = $0 }
            }
        }
    }
}

private struct NativeQrConfirmationPage: View {
    let catalog: IosNativeCatalog
    let requestId: String

    @State private var handle: NativeScreenHandle<IosNativeQrLogin>?
    @State private var state: IosQrLoginState?

    var body: some View {
        Form {
            switch state?.stage {
            case .requiresLogin:
                NavigationLink("Sign In", value: NativeAccountRoute.email)
                Button("Try Again") { handle?.value.retry() }
            case .confirm:
                Section {
                    Label(state?.deviceName ?? String(localized: "New Device"), systemImage: "tv")
                    Button("Approve Sign-In") { handle?.value.confirm(approved: true) }
                    Button("Reject Sign-In", role: .destructive) { handle?.value.confirm(approved: false) }
                }
                .disabled(state?.busy == true)
                if state?.failed == true { Text("Couldn’t Confirm Sign-In").foregroundStyle(.red) }
            case .approved:
                Label("Sign-In Approved", systemImage: "checkmark.circle")
            case .rejected:
                Label("Sign-In Rejected", systemImage: "xmark.circle")
            case .expired, .handled:
                Label("Sign-In Code Is No Longer Valid", systemImage: "exclamationmark.circle")
            case .failed:
                Label("Couldn’t Load Content", systemImage: "exclamationmark.circle")
                Button("Try Again") { handle?.value.retry() }
            default:
                ProgressView()
            }
        }
        .navigationTitle("Confirm Sign-In")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let current = handle ?? NativeScreenHandle(catalog.openQrLogin(requestId: requestId)) { $0.close() }
            handle = current
            await observeNative(current.value.observe) { state = $0 }
        }
    }
}

private struct NativeQrScanner: View {
    let catalog: IosNativeCatalog
    let onScan: (String) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var cameraPermission: Bool?
    @State private var scannerFailed = false
    @State private var invalidCode = false

    var body: some View {
        Group {
            if !DataScannerViewController.isSupported || scannerFailed {
                ContentUnavailableView("Camera Unavailable", systemImage: "camera.slash")
            } else if cameraPermission == true {
                NativeQrCamera { payload in
                    guard let id = catalog.qrLoginRequestId(content: payload) else {
                        invalidCode = true
                        return false
                    }
                    onScan(id)
                    return true
                } onFailure: {
                    scannerFailed = true
                }
                .overlay(alignment: .bottom) {
                    Text(invalidCode ? LocalizedStringKey("Unrecognized Sign-In Code") : LocalizedStringKey("Point Your Camera at the Sign-In Code"))
                        .padding(12)
                        .background(.regularMaterial, in: .capsule)
                        .padding()
                }
            } else if cameraPermission == false {
                ContentUnavailableView {
                    Label("Camera Access Required", systemImage: "camera")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Scan Sign-In Code")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            if scenePhase == .active && DataScannerViewController.isSupported {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    cameraPermission = await AVCaptureDevice.requestAccess(for: .video)
                } else {
                    cameraPermission = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                    scannerFailed = false
                }
            }
        }
    }
}

private struct NativeQrCamera: UIViewControllerRepresentable {
    let onPayload: (String) -> Bool
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload, onFailure: onFailure) }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning && !context.coordinator.handled else { return }
        do {
            try scanner.startScanning()
        } catch {
            Task { @MainActor in onFailure() }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Bool
        let onFailure: () -> Void
        private(set) var handled = false

        init(onPayload: @escaping (String) -> Bool, onFailure: @escaping () -> Void) {
            self.onPayload = onPayload
            self.onFailure = onFailure
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !handled else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue, onPayload(payload) {
                    handled = true
                    scanner.stopScanning()
                    return
                }
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onFailure()
        }
    }
}
