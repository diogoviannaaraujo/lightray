import LightrayCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: ClientSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAddComputer = false
    @State private var showingKeyboard = false
    @State private var showingTools = false
    @State private var isZoomed = false
    @State private var zoomResetGeneration: UInt64 = 0
    @AppStorage(SessionTools.cornerKey) private var toolsCorner = SessionTools.Corner.topTrailing

    var body: some View {
        Group {
            if session.isPresentingSession {
                stream
            } else {
                NavigationStack {
                    computers
                        .navigationTitle("Lightray")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button("Add computer", systemImage: "plus") { showingAddComputer = true }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingAddComputer) {
            AddComputerView(session: session)
                .presentationDetents([.large])
        }
        .alert("Connection", isPresented: Binding(
            get: { session.errorMessage != nil && !showingAddComputer },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .onChange(of: session.inputEnabled) { _, enabled in
            if !enabled { session.releaseInput() }
        }
        .onChange(of: session.canSendInput) { _, enabled in
            if !enabled { showingKeyboard = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                showingKeyboard = false
                session.releaseInput()
            }
            if phase == .background { session.suspend() }
            if phase == .active { session.foreground() }
        }
    }

    private var computers: some View {
        Group {
            if session.hosts.isEmpty {
                ContentUnavailableView {
                    Label("Your computer, on iPad", systemImage: "display")
                } description: {
                    Text("Connect to a Lightray host to stream its display and control it with touch, a trackpad, or a keyboard.")
                } actions: {
                    Button("Add computer", systemImage: "plus") { showingAddComputer = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                List {
                    Section("Computers") {
                        ForEach(session.hosts, id: \.pairingID) { host in
                            Button { session.connect(host) } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                        .frame(width: 40)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(host.name).font(.headline).foregroundStyle(.primary)
                                        Text(host.address).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                            }
                            .swipeActions {
                                Button("Forget", role: .destructive) { session.forget(host) }
                            }
                            .contextMenu {
                                Button("Connect", systemImage: "play") { session.connect(host) }
                                Button("Forget computer", systemImage: "trash", role: .destructive) { session.forget(host) }
                            }
                        }
                    }
                    Section {
                        Label("Drag to move the pointer. Tap to click, or tap with two fingers to right-click. Double-tap and drag to drag. Drag with two fingers to scroll, and pinch to zoom.", systemImage: "hand.draw")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The remote display fills the window; the session's controls float over it.
    private var stream: some View {
        ZStack {
            Color.black
                .ignoresSafeArea(.container)
            // Edge to edge, but clear of the onscreen keyboard so the picture moves up above it.
            StreamSurface(renderer: session.renderer, videoSize: session.videoSize,
                          displayID: session.selectedDisplay,
                          inputEnabled: session.canSendInput && scenePhase == .active,
                          inputResetGeneration: session.inputResetGeneration,
                          zoomResetGeneration: zoomResetGeneration,
                          softwareKeyboardVisible: showingKeyboard,
                          onInput: session.send,
                          onKeyboardDismissed: { showingKeyboard = false },
                          onZoomedChange: { isZoomed = $0 },
                          onTouch: { if showingTools { withAnimation(.bouncy) { showingTools = false } } })
                .id(ObjectIdentifier(session.renderer))
                .ignoresSafeArea(.container)
                .accessibilityLabel("Remote display")

            if !session.hasPicture {
                VStack(spacing: 14) {
                    if session.phase == .connecting { ProgressView().tint(.white) }
                    Image(systemName: "display").font(.largeTitle)
                    Text(session.status).font(.headline).multilineTextAlignment(.center)
                    if session.phase == .connected {
                        Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(28)
                .foregroundStyle(.white)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 24))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(session.phase == .connected)
            }

            if session.showStatistics && !session.statistics.isEmpty {
                Text(session.statistics)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Stream statistics: \(session.statistics)")
                    // Opposite the session tools.
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: toolsCorner.isLeading ? .topTrailing : .topLeading)
            }

            SessionTools(session: session, expanded: $showingTools, showingKeyboard: $showingKeyboard,
                         keyboardAvailable: session.canSendInput && scenePhase == .active,
                         isZoomed: isZoomed, resetZoom: { zoomResetGeneration &+= 1 })
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Touchpad drags near an edge need a second swipe to reach Home or Notification Center.
        .defersSystemGestures(on: .vertical)
        .onDisappear {
            showingKeyboard = false
            showingTools = false
            isZoomed = false
        }
    }
}

private struct AddComputerView: View {
    @Bindable var session: ClientSession
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var token = ""
    @State private var remember = true
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hostname or IP address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("hostAddress")
                    TextField("Name (optional)", text: $name)
                } header: { Text("Computer") } footer: {
                    Text("Use the host’s LAN address or hostname. The default UDP port is 7373; append :port to use another.")
                }
                Section {
                    SecureField("Pairing token (lr1-…)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pairingToken")
                    Button("Import pairing file", systemImage: "doc.badge.plus") { importing = true }
                    Toggle("Remember this computer", isOn: $remember)
                } header: { Text("Pairing") } footer: {
                    Text("On your Mac, run lightray-host pair and copy the token or save it to a text file. Remembered pairings are stored in this iPad’s Keychain.")
                }
                Section {
                    Label("Start the Lightray host and allow Local Network access when this iPad asks.", systemImage: "network")
                }
                if let message = importError ?? session.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.errorMessage = nil; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        importError = nil
                        session.errorMessage = nil
                        session.connect(address: address, name: name, token: token, remember: remember)
                        if session.isPresentingSession { token = ""; dismiss() }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.isEmpty)
                    .accessibilityIdentifier("connectComputer")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
                do {
                    let url = try result.get()
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let bytes = try file.read(upToCount: 4097) ?? Data()
                    guard bytes.count <= 4096, let text = String(data: bytes, encoding: .utf8), Pairing(token: text) != nil else {
                        importError = "Choose a text file containing one complete lr1- pairing token."
                        return
                    }
                    token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    importError = nil
                } catch { importError = "Could not import the pairing file: \(error.localizedDescription)" }
            }
        }
    }
}
