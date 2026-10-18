import AppKit
import LightrayCore
import LightrayHostSupport
import Observation
import SystemConfiguration

enum HostSettingsPage: String, CaseIterable, Identifiable {
    case general, streaming, permissions, pairing, diagnostics
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .streaming: "Streaming"
        case .permissions: "Permissions"
        case .pairing: "Pairing"
        case .diagnostics: "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .streaming: "display"
        case .permissions: "hand.raised"
        case .pairing: "link"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct HostSettingsBanner: Identifiable {
    enum Action { case activate, backgroundSettings, screenPermission, inputPermission, revealApp }
    let id: String
    let title: String
    let message: String
    let button: String
    let action: Action
}

/// Adding a device: name it, show its code while the host waits for its first connection, then
/// confirm it paired. The code is never shown again.
enum AddDeviceStep: Equatable {
    case naming
    case waiting(PairedDevice, PairingInvite)
    case paired(PairedDevice)
    case expired(String)
}

/// Keeps drafts separate from the running service and observes service-owned permission state.
@MainActor @Observable final class HostSettingsModel {
    var page: HostSettingsPage? = .general
    var port: String
    var quality: HostQuality
    var allowInput: Bool
    private(set) var snapshot: HostSnapshot
    private(set) var registrationState: RegistrationState
    private(set) var busy = false
    private(set) var isActive: Bool
    private(set) var hasServiceSnapshot = false
    private(set) var configurationError: String?
    private(set) var notice: String?
    private(set) var noticeIsError = false
    /// Paired devices, oldest first; codes still waiting are shown only while being added.
    private(set) var devices: [PairedDevice] = []
    private(set) var devicesError: String?
    var addDevice: AddDeviceStep?
    var newDeviceName = ""
    private(set) var addDeviceMessage: String?
    var revoking: PairedDevice?
    @ObservationIgnored let service: HostService
    @ObservationIgnored weak var window: NSWindow?

    init(service: HostService) {
        self.service = service
        port = String(service.settings.port)
        quality = service.settings.quality
        allowInput = service.settings.allowInput
        snapshot = service.snapshot
        registrationState = service.registration.state
        isActive = service.isActive
        configurationError = service.configurationError
        hasServiceSnapshot = service.hasServiceSnapshot
        busy = service.busy
        service.onChange = { [weak self] in self?.refresh() }
        reloadDevices()
    }

    var canEdit: Bool { !isActive && !busy && configurationError == nil }
    var canStart: Bool { !busy && configurationError == nil && registrationState != .notFound }
    var validPort: UInt16? {
        guard let value = UInt16(port), value > 0 else { return nil }
        return value
    }
    /// A new code is accepted only by a running host, which waits for the device's first connection.
    var canAddDevice: Bool { snapshot.state == .running && hasServiceSnapshot && !busy }
    var computerName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }
    func isConnected(_ device: PairedDevice) -> Bool { snapshot.connectedDevice == device.hexID }
    var address: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
        return "\(name).local:\(port)"
    }
    var statusTitle: String {
        if busy { return "Updating sharing…" }
        if registrationState == .enabled && !hasServiceSnapshot && snapshot.state == .stopped {
            return "Checking service…"
        }
        switch snapshot.state {
        case .running: return "Ready to connect"
        case .starting: return "Starting sharing…"
        case .stopping: return "Stopping sharing…"
        case .blocked: return "Setup needed"
        case .failed: return "Needs attention"
        case .stopped: return "Sharing is off"
        }
    }
    var registrationTitle: String {
        switch registrationState {
        case .notRegistered: "Not installed"
        case .enabled: "Enabled at login"
        case .requiresApproval: "Approval required"
        case .notFound: "Service missing"
        }
    }
    var banners: [HostSettingsBanner] {
        guard configurationError == nil else { return [] }
        var result: [HostSettingsBanner] = []
        switch registrationState {
        case .notRegistered:
            result.append(.init(id: "service", title: "Set up background sharing",
                                message: "Install and activate the service to share this Mac, including after you log in.",
                                button: "Install & Activate", action: .activate))
        case .requiresApproval:
            result.append(.init(id: "service", title: "Allow the background service",
                                message: "Enable Lightray Host in System Settings → Login Items & Extensions.",
                                button: "Open System Settings", action: .backgroundSettings))
        case .notFound:
            result.append(.init(id: "service", title: "The host service is missing",
                                message: "Reinstall Lightray Host from the disk image to restore its bundled service.",
                                button: "Show Application", action: .revealApp))
        case .enabled:
            if !busy && (snapshot.state == .failed || (snapshot.state == .stopped && hasServiceSnapshot) ||
                         (snapshot.state == .blocked && hasServiceSnapshot && snapshot.screenAllowed &&
                          (!service.settings.allowInput || snapshot.inputAllowed))) {
                result.append(.init(id: "service", title: "Sharing is not running",
                                    message: snapshot.message, button: "Activate Service", action: .activate))
            }
        }
        // False defaults or an unavailable agent do not establish that permission is missing.
        if registrationState == .enabled && hasServiceSnapshot {
            if !snapshot.screenAllowed {
                result.append(.init(id: "screen", title: "Screen Recording permission needed",
                                    message: "Allow Lightray Host to capture your displays so paired devices can see this Mac.",
                                    button: "Allow Screen Recording…", action: .screenPermission))
            }
            if service.settings.allowInput && !snapshot.inputAllowed {
                result.append(.init(id: "input", title: "Accessibility permission needed",
                                    message: "Allow LightrayHostService to use the keyboard and mouse for remote control.",
                                    button: "Allow Accessibility…", action: .inputPermission))
            }
        }
        return result
    }

    private func refresh() {
        snapshot = service.snapshot
        registrationState = service.registration.state
        busy = service.busy
        isActive = service.isActive
        hasServiceSnapshot = service.hasServiceSnapshot
        configurationError = service.configurationError
        reloadDevices()
    }

    private func reloadDevices() {
        let all: [PairedDevice]
        do { all = try service.devices.load(); devicesError = nil }
        catch { devicesError = error.localizedDescription; return }
        let paired = all.filter { !$0.isWaiting }.sorted { $0.created < $1.created }
        if paired != devices { devices = paired }
        guard case .waiting(let device, _) = addDevice else { return }
        if let current = all.first(where: { $0.id == device.id }), current.accepts(at: Date()) {
            if !current.isWaiting { addDevice = .paired(current) }
        } else {
            try? service.devices.removeWaiting(id: device.id)
            addDevice = .expired(device.name)
        }
    }

    func perform(_ action: HostSettingsBanner.Action) {
        switch action {
        case .activate: startSharing()
        case .backgroundSettings: service.registration.openSettings()
        case .screenPermission: requestPermission("screen")
        case .inputPermission: requestPermission("input")
        case .revealApp: NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    func toggleSharing() {
        if isActive {
            clearNotice()
            Task { await service.stop() }
        } else { startSharing() }
    }

    func startSharing() {
        guard canStart else { return }
        guard let number = validPort else {
            page = .general
            showNotice("Enter a port between 1 and 65535.", isError: true)
            return
        }
        clearNotice()
        let profile = quality
        let input = allowInput
        Task { await service.start(port: number, quality: profile, allowInput: input) }
    }

    func requestPermission(_ permission: String) {
        clearNotice()
        Task { await service.requestPermission(permission) }
    }

    func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        showNotice("Mac address copied.")
    }

    func showAddDevice() {
        guard canAddDevice else { return }
        newDeviceName = ""; addDeviceMessage = nil
        addDevice = .naming
    }

    func beginAdding() {
        do {
            let device = try service.devices.addWaiting(name: newDeviceName)
            addDeviceMessage = nil
            addDevice = .waiting(device, PairingInvite(address: address, name: computerName, pairing: device.pairing))
        } catch { addDeviceMessage = error.localizedDescription }
    }

    func retryAdding() {
        guard case .expired(let name) = addDevice else { return }
        newDeviceName = name; addDeviceMessage = nil
        addDevice = .naming
    }

    /// Closing the sheet withdraws a code still waiting; a device that already connected stays.
    func closeAddDevice() {
        if case .waiting(let device, _) = addDevice {
            do { try service.devices.removeWaiting(id: device.id) }
            catch { showNotice("Could not withdraw the code for \(device.name): \(error.localizedDescription)", isError: true) }
        }
        addDevice = nil; addDeviceMessage = nil
        reloadDevices()
    }

    func copyCode() {
        guard case .waiting(let device, _) = addDevice else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // The nspasteboard.org marker that clipboard history tools skip.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setString(device.pairing.token, forType: .string)
        addDeviceMessage = "Code copied. Paste it into Lightray on \(device.name)."
    }

    func exportCode() {
        guard case .waiting(let device, _) = addDevice, let window = NSApp.keyWindow ?? window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lightray pairing for \(device.name.replacingOccurrences(of: "/", with: "-")).txt"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try Data((device.pairing.token + "\n").utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                self?.addDeviceMessage = "Pairing file saved. Delete it once \(device.name) is paired."
            } catch { self?.addDeviceMessage = "Could not save the pairing file: \(error.localizedDescription)" }
        }
    }

    func revoke(_ device: PairedDevice) {
        revoking = nil
        let connected = isConnected(device)
        do {
            try service.devices.remove(id: device.id)
            showNotice(connected ? "\(device.name) was revoked and disconnected." : "\(device.name) was revoked.")
        } catch { showNotice("Could not revoke \(device.name): \(error.localizedDescription)", isError: true) }
        reloadDevices()
    }

    func showLog() {
        if FileManager.default.fileExists(atPath: service.logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([service.logURL])
        } else { showNotice("The host log will be available after starting sharing.") }
    }

    func clearNotice() { notice = nil; noticeIsError = false }

    private func showNotice(_ message: String, isError: Bool = false) {
        notice = message; noticeIsError = isError
    }
}
