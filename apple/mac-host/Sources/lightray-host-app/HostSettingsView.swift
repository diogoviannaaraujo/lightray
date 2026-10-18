import SwiftUI
import LightrayHostSupport

@MainActor struct HostSettingsView: View {
    @Bindable var model: HostSettingsModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                Section("Settings") {
                    ForEach(HostSettingsPage.allCases.filter { $0 != .diagnostics }) { page in
                        Label(page.title, systemImage: page.symbol).tag(page)
                    }
                }
                Section("Support") {
                    Label(HostSettingsPage.diagnostics.title, systemImage: HostSettingsPage.diagnostics.symbol)
                        .tag(HostSettingsPage.diagnostics)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Lightray Host")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "display").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lightray Host").font(.callout.weight(.medium))
                        Text(model.statusTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Circle()
                        .fill(model.snapshot.state == .running ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                .padding(16)
            }
        } detail: {
            VStack(spacing: 0) {
                if !model.banners.isEmpty || model.configurationError != nil || model.notice != nil {
                    VStack(spacing: 10) {
                        if let error = model.configurationError {
                            messageBanner(title: "Host settings could not be loaded", message: error, isError: true)
                        }
                        ForEach(model.banners) { warningBanner($0) }
                        if let notice = model.notice {
                            messageBanner(title: model.noticeIsError ? "Needs attention" : "Done",
                                          message: notice, isError: model.noticeIsError)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                }
                Form {
                    switch model.page ?? .general {
                    case .general: generalSettings
                    case .streaming: streamingSettings
                    case .permissions: permissionSettings
                    case .pairing: pairingSettings
                    case .diagnostics: diagnosticSettings
                    }
                }
                .formStyle(.grouped)
            }
            .background(.background)
            .sheet(isPresented: Binding(get: { model.addDevice != nil }, set: { if !$0 { model.closeAddDevice() } })) {
                AddDeviceSheet(model: model)
            }
            .confirmationDialog("Revoke \(model.revoking?.name ?? "this device")?",
                                isPresented: Binding(get: { model.revoking != nil }, set: { if !$0 { model.revoking = nil } }),
                                presenting: model.revoking) { device in
                Button("Revoke", role: .destructive) { model.revoke(device) }
            } message: { device in
                Text(device.shared
                     ? "Every device still using the earlier pairing code will be disconnected and can’t connect again until you add it again."
                     : "\(device.name) will be disconnected and can’t connect again until you add it again.")
            }
            .navigationTitle((model.page ?? .general).title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.isActive ? "Stop Sharing" : "Start Sharing", action: model.toggleSharing)
                        .disabled(model.busy || (!model.isActive && !model.canStart))
                        .help(model.isActive ? "Stop sharing and disable the background service at login" : "Activate background sharing on this Mac")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var generalSettings: some View {
        Group {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "display")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Share This Mac").font(.title2.weight(.semibold))
                        Text(model.statusTitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating sharing") }
                }
                .padding(.vertical, 8)
                LabeledContent("Background service", value: model.registrationTitle)
            } footer: {
                Text("Sharing stays available when you close or quit this app. Stop Sharing turns it off until you activate it again.")
            }
            Section {
                TextField("UDP port", text: $model.port)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .disabled(!model.canEdit)
                    .onChange(of: model.port) { model.clearNotice() }
                if model.validPort == nil {
                    Label("Enter a port between 1 and 65535.", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red)
                }
                addressRow
                Button("Copy Mac Address", systemImage: "doc.on.doc", action: model.copyAddress)
            } header: {
                Text("Connection")
            } footer: {
                Text("Use this address on your local network, or connect with this Mac’s IP address or Tailscale name. Stop sharing to change the port.")
            }
            Section("Background Activity") {
                LabeledContent("Start at login", value: model.registrationState == .enabled ? "Enabled with sharing" :
                                (model.registrationState == .requiresApproval ? "Awaiting approval" : "Off"))
                Button("Open Login Items & Extensions…") { model.perform(.backgroundSettings) }
            }
        }
    }

    private var streamingSettings: some View {
        Section {
            Picker("Quality", selection: $model.quality) {
                ForEach(HostQuality.allCases, id: \.self) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .disabled(!model.canEdit)
            LabeledContent("Frame rate", value: "\(model.quality.frameRate) fps")
            LabeledContent("Resolution", value: model.quality == .native ? "Full display resolution" : "Half display resolution")
        } header: {
            Text("Video Quality")
        } footer: {
            Text("Balanced uses fewer resources. Smooth prioritizes motion, and Native preserves display detail. Stop sharing to change quality; your choice is saved when sharing starts.")
        }
    }

    private var permissionSettings: some View {
        Group {
            Section {
                permissionRow("Screen Recording", subtitle: "Required to share your displays.",
                              allowed: model.snapshot.screenAllowed, action: .screenPermission)
                permissionRow("Accessibility", subtitle: model.allowInput ? "Required for keyboard and mouse control." : "Optional while remote control is off.",
                              allowed: model.snapshot.inputAllowed, action: .inputPermission)
            } header: {
                Text("macOS Permissions")
            } footer: {
                Text("Activate the service before granting access. macOS may list Screen Recording under Lightray Host and Accessibility under LightrayHostService. If macOS asks you to restart, use Retry Sharing in Diagnostics.")
            }
            Section {
                Toggle("Allow keyboard and mouse control", isOn: $model.allowInput)
                    .disabled(!model.canEdit)
            } header: {
                Text("Remote Control")
            } footer: {
                Text("Turn this off to share your screen without allowing input from paired devices. Stop sharing to change this setting; it is saved when sharing starts.")
            }
        }
    }

    private var pairingSettings: some View {
        Group {
            Section {
                if let error = model.devicesError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                } else if model.devices.isEmpty {
                    Text("No devices yet.").foregroundStyle(.secondary)
                }
                ForEach(model.devices) { deviceRow($0) }
                Button("Add Device…", systemImage: "plus", action: model.showAddDevice)
                    .disabled(!model.canAddDevice)
            } header: {
                Text("Paired Devices")
            } footer: {
                Text(model.canAddDevice
                     ? "Each device gets its own code, shown once. Revoke a device to disconnect it and stop it from connecting again."
                     : "Start sharing to add a device. A new code works only while this Mac waits for the device’s first connection.")
            }
            if model.devices.contains(where: \.shared) {
                Section {
                    Label("Devices you paired before this update share the earlier pairing code. Add each of them on its own, then revoke the earlier code.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                addressRow
                Button("Copy Mac Address", systemImage: "doc.on.doc", action: model.copyAddress)
            } header: {
                Text("Connect a Device")
            } footer: {
                Text("In Lightray, choose Add Host on Mac or Add computer on iPad, enter this Mac’s address, and paste the device’s pairing code. On iPad you can scan its QR code instead.")
            }
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.shared ? "key" : "laptopcomputer.and.ipad")
                .foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                Group {
                    if let last = device.lastConnected {
                        Text("Paired \(device.paired ?? device.created, format: .dateTime.day().month().year()) · Last connected \(last, format: .relative(presentation: .named))")
                    } else {
                        Text("Paired \(device.paired ?? device.created, format: .dateTime.day().month().year())")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if model.isConnected(device) {
                Label("Connected", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon).font(.callout)
                    .foregroundStyle(.green)
            }
            Button("Revoke…", role: .destructive) { model.revoking = device }
                .accessibilityLabel("Revoke \(device.name)")
        }
        .accessibilityElement(children: .contain)
    }

    private var diagnosticSettings: some View {
        Group {
            Section("Host Status") {
                LabeledContent("Sharing", value: model.statusTitle)
                LabeledContent("Background service", value: model.registrationTitle)
                Text(model.snapshot.message).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry Sharing", systemImage: "arrow.clockwise", action: model.startSharing)
                    .disabled(!model.canStart)
            }
            Section {
                Button("Show Host Log", systemImage: "doc.text.magnifyingglass", action: model.showLog)
                LabeledContent("Version", value: model.service.build)
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Retry Sharing activates the service with your current settings. Service registration and streaming readiness are reported separately.")
            }
        }
    }

    private var addressRow: some View {
        LabeledContent("Mac address") {
            Text(model.address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func permissionRow(_ title: String, subtitle: String, allowed: Bool,
                               action: HostSettingsBanner.Action) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Text(model.hasServiceSnapshot ? (allowed ? "Allowed" : "Not allowed") : "Not checked")
                .foregroundStyle(.secondary)
            if !model.hasServiceSnapshot || !allowed {
                Button("Allow…") { model.perform(action) }
                    .disabled(model.busy || model.registrationState != .enabled)
                    .accessibilityLabel("Allow \(title)")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func warningBanner(_ banner: HostSettingsBanner) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.title).font(.callout.weight(.semibold))
                    Text(banner.message).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        .help(banner.message)
                }
            }
            Button(banner.button) { model.perform(banner.action) }
                .buttonStyle(.bordered)
                .disabled(model.busy || (banner.action == .activate && !model.canStart))
                .padding(.leading, 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.2)))
        .accessibilityElement(children: .contain)
    }

    private func messageBanner(title: String, message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(4).help(message)
            }
            Spacer(minLength: 0)
            if model.configurationError == nil {
                Button(action: model.clearNotice) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss message")
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
