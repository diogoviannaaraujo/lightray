import Foundation
import ServiceManagement

public enum RegistrationState: Equatable { case notRegistered, enabled, requiresApproval, notFound }

@MainActor public protocol ServiceRegistration {
    var state: RegistrationState { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

@MainActor public final class AppServiceRegistration: ServiceRegistration {
    private let service = SMAppService.agent(plistName: HostIdentity.plist)
    public init() {}
    public var state: RegistrationState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:
            // A valid bundled agent can be unknown to launchd until its first registration.
            let bundle = Bundle.main.bundleURL
            let plist = bundle.appendingPathComponent("Contents/Library/LaunchAgents/" + HostIdentity.plist)
            let helper = bundle.appendingPathComponent(HostIdentity.helperPath + "/Contents/MacOS/lightray-host")
            return FileManager.default.fileExists(atPath: plist.path) && FileManager.default.isExecutableFile(atPath: helper.path)
                ? .notRegistered : .notFound
        @unknown default: return .notFound
        }
    }
    public func register() throws { try service.register() }
    public func unregister() async throws { try await service.unregister() }
    public func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
