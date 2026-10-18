import LightrayCore
import SwiftUI
import UniformTypeIdentifiers

struct HostsView: View {
    @Bindable var model: HostLibraryModel
    var connect: (PairedHost) -> Void
    @State private var hostToForget: PairedHost?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let notice = model.notice { noticeBanner(notice) }
                if model.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("Your hosts, in one place", systemImage: "desktopcomputer")
                    } description: {
                        Text("Add a host to securely connect to its desktop.\nYour paired hosts will appear here.")
                    } actions: {
                        Button("Add Host", systemImage: "plus", action: { model.addHost() })
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    hostList
                }
            }
            .background(.background)
            .navigationTitle("Lightray")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus", action: { model.addHost() })
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut("n")
                        .help("Add a host (⌘N)")
                        .accessibilityIdentifier("addHost")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").accessibilityHidden(true)
                    Text("\(model.hosts.count) paired \(model.hosts.count == 1 ? "host" : "hosts")")
                    Spacer()
                    Text("Availability is checked when you connect.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.bar)
            }
        }
        .sheet(item: $model.draft) { draft in
            HostEditorView(model: model, initialDraft: draft)
        }
        .confirmationDialog("Forget \(hostToForget?.name ?? "host")?", isPresented: Binding(
            get: { hostToForget != nil }, set: { if !$0 { hostToForget = nil } }
        ), titleVisibility: .visible) {
            if let host = hostToForget {
                Button("Forget Host", role: .destructive) { model.forgetHost(host); hostToForget = nil }
            }
        } message: {
            Text("Remove this host and its saved pairing from this Mac. You can add it again with its pairing code.")
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var hostList: some View {
        List {
            Section {
                ForEach(model.hosts, id: \.pairingID) { host in
                    HStack(spacing: 16) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(.tint)
                            .frame(width: 54, height: 54)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(host.name).font(.headline).lineLimit(1)
                            Text(host.address).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .textSelection(.enabled)
                        Spacer(minLength: 16)
                        Button("Connect") { connect(host) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Connect to \(host.name)")
                        Menu {
                            hostActions(host)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Options for \(host.name)")
                    }
                    .padding(.vertical, 12)
                    .contextMenu { hostActions(host) }
                    .accessibilityElement(children: .contain)
                }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paired Hosts").font(.title2.weight(.semibold)).foregroundStyle(.primary)
                    Text("Choose a host to start a remote session.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .textCase(nil)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("pairedHosts")
    }

    @ViewBuilder private func hostActions(_ host: PairedHost) -> some View {
        Button("Connect", systemImage: "play") { connect(host) }
        Button("Edit Host…", systemImage: "pencil") { model.editHost(host) }
        Divider()
        Button("Forget Host…", systemImage: "trash", role: .destructive) { hostToForget = host }
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }
}

private struct HostEditorView: View {
    @Bindable var model: HostLibraryModel
    let initialDraft: HostDraft
    @State private var importing = false
    @FocusState private var addressFocused: Bool

    // The model owns the draft so display changes and validation remain visible in the sheet.
    private var draft: Binding<HostDraft> {
        Binding(get: { model.draft ?? initialDraft }, set: { model.draft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: initialDraft.isEditing ? "desktopcomputer" : "plus.rectangle.on.rectangle")
                    .font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(initialDraft.isEditing ? "Edit Host" : "Add Host").font(.title2.weight(.semibold))
                    Text("Connect using the host’s address and pairing code.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)

            Form {
                Section {
                    TextField("Address", text: draft.address, prompt: Text("Hostname or IP address"))
                        .focused($addressFocused)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("hostAddress")
                    TextField("Name", text: draft.name, prompt: Text("Optional"))
                } header: { Text("Host") } footer: {
                    Text("Use a local IP address or hostname. Add :port if the host uses a port other than 7373.")
                }
                Section {
                    SecureField("Pairing code", text: draft.token, prompt: Text("lr1-…"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pairingToken")
                    HStack {
                        if Pairing(token: draft.wrappedValue.token) != nil {
                            Label("Pairing ready", systemImage: "checkmark.shield")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import Pairing File…", systemImage: "doc.badge.plus") { importing = true }
                    }
                } header: { Text("Pairing") } footer: {
                    Text("Copy the pairing code or export a pairing file from Lightray Host on the computer you want to connect to.")
                }
                Section("Session") {
                    Picker("Open on", selection: draft.displayID) {
                        Text("Default display").tag(nil as UInt32?)
                        ForEach(model.displays) { display in
                            Text(display.title).tag(Optional(display.id))
                        }
                    }
                }
                if let error = draft.wrappedValue.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red)
                            .accessibilityIdentifier("hostError")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !model.canRemember {
                    Text("Hosts are kept for this session only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.draft = nil }
                    .keyboardShortcut(.cancelAction)
                Button(initialDraft.isEditing ? "Save Changes" : "Add Host") {
                    _ = model.saveHost(draft.wrappedValue)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.wrappedValue.canSubmit)
                .accessibilityIdentifier("saveHost")
            }
            .padding(20)
        }
        .frame(width: 540, height: 620)
        .background(.background)
        .onAppear { addressFocused = true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let url = try result.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: 1025) ?? Data()
                guard data.count <= 1024, let token = String(data: data, encoding: .utf8), Pairing(token: token) != nil else {
                    draft.wrappedValue.error = "Choose a text file containing one complete lr1- pairing code."
                    return
                }
                draft.wrappedValue.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.wrappedValue.error = nil
            } catch CocoaError.userCancelled {
                // Dismissing the file picker leaves the current draft intact.
            } catch {
                draft.wrappedValue.error = "Could not read the pairing file. Choose a readable file and try again."
            }
        }
    }
}
