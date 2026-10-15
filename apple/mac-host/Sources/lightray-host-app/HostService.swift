import Foundation
import LightrayHostSupport

/// Settings and registration belong to this app; streaming belongs to the independent agent.
@MainActor final class HostService {
    var onChange: (() -> Void)?
    private(set) var snapshot = HostSnapshot()
    private(set) var busy = false
    private(set) var settings = HostSettings()
    private(set) var configurationError: String?
    private var refreshing = false
    private var revision = 0
    let store: HostSettingsStore
    let registration: ServiceRegistration
    let control: HostControlClient
    let build: String
    var logURL: URL { HostIdentity.logURL }
    var isActive: Bool { settings.enabled || registration.state == .enabled || registration.state == .requiresApproval }

    init(store: HostSettingsStore = HostSettingsStore(), registration: ServiceRegistration? = nil,
         control: HostControlClient? = nil, build: String? = nil) {
        self.store = store
        self.registration = registration ?? AppServiceRegistration()
        self.control = control ?? XPCClient()
        self.build = build ?? "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "0")-\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "0")"
        do { settings = try store.loadOrMigrate() }
        catch { configurationError = error.localizedDescription; snapshot = HostSnapshot(state: .failed, message: error.localizedDescription) }
    }

    func start(port: UInt16, quality: HostQuality, allowInput: Bool) async {
        guard !busy, configurationError == nil else { return }
        busy = true; revision += 1; onChange?()
        defer { busy = false; onChange?() }
        do {
            var next = settings
            next.port = port; next.quality = quality; next.allowInput = allowInput; next.enabled = true
            try store.save(next); settings = next
            // An explicit start also retries a failed service with the latest saved configuration.
            if registration.state == .enabled { try? await control.stopSharing(); try await registration.unregister() }
            if registration.state != .requiresApproval { try registration.register() }
            if registration.state == .enabled {
                settings.registeredBuild = build; try store.save(settings)
                snapshot = HostSnapshot(state: .starting, message: "Preparing sharing…")
            } else { snapshot = HostSnapshot(state: .blocked, message: "Allow Lightray Host in System Settings → Login Items & Extensions.") }
        } catch { snapshot = HostSnapshot(state: .failed, message: error.localizedDescription) }
    }

    func stop() async {
        guard !busy else { return }
        busy = true; revision += 1; onChange?()
        defer { busy = false; onChange?() }
        settings.enabled = false
        var settingsError = configurationError
        if settingsError == nil {
            do { try store.save(settings) }
            catch { settingsError = error.localizedDescription }
        }
        snapshot = HostSnapshot(state: .stopping, message: "Stopping sharing…"); onChange?()
        do {
            // Always unregister, even if settings are corrupt, unwritable, or XPC is unavailable.
            // Registration is what permits a future login to launch the service.
            if registration.state == .enabled { try? await control.stopSharing() }
            if registration.state != .notRegistered { try await registration.unregister() }
            snapshot = HostSnapshot(message: settingsError.map { "Sharing is off. Settings need attention: \($0)" } ?? "Sharing is off.")
        } catch { snapshot = HostSnapshot(state: .failed, message: "Could not finish stopping sharing: \(error.localizedDescription). Retry Stop Sharing.") }
    }

    func refresh() async {
        guard !busy, !refreshing, configurationError == nil else { return }
        refreshing = true
        let observedRevision = revision
        defer { refreshing = false; onChange?() }
        switch registration.state {
        case .notRegistered:
            snapshot = HostSnapshot(state: settings.enabled ? .failed : .stopped,
                                    message: settings.enabled ? "The service is not registered. Choose Start Sharing to retry." : "Sharing is off.")
        case .requiresApproval:
            snapshot = HostSnapshot(state: .blocked, message: "Background sharing needs approval in System Settings → Login Items & Extensions.")
        case .notFound:
            snapshot = HostSnapshot(state: .failed, message: "The bundled host service was not found. Reinstall Lightray Host.")
        case .enabled:
            do {
                let value = try await control.status()
                if revision == observedRevision { snapshot = value }
            } catch {
                if revision == observedRevision { snapshot = HostSnapshot(state: .failed, message: error.localizedDescription) }
            }
        }
    }

    func requestPermission(_ permission: String) async {
        guard !busy, registration.state == .enabled else {
            snapshot = HostSnapshot(state: .blocked, message: "Choose Start Sharing first, then allow the service's permissions.")
            onChange?(); return
        }
        do { snapshot = try await control.requestPermission(permission) }
        catch { snapshot = HostSnapshot(state: .failed, message: error.localizedDescription) }
        onChange?()
    }

    /// Only update an already approved, enabled service. Never undo a System Settings decision.
    func refreshAfterUpgrade() async {
        guard !busy, configurationError == nil, settings.enabled, registration.state == .enabled,
              settings.registeredBuild != build else { await refresh(); return }
        busy = true; revision += 1; onChange?()
        defer { busy = false; onChange?() }
        do {
            try? await control.stopSharing()
            try await registration.unregister()
            try registration.register()
            guard registration.state == .enabled else { throw HostFailure.message("The updated service needs approval in System Settings.") }
            settings.registeredBuild = build; try store.save(settings)
            snapshot = HostSnapshot(state: .starting, message: "Starting the updated host service…")
        } catch { snapshot = HostSnapshot(state: .failed, message: error.localizedDescription) }
    }
}
