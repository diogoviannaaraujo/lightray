import Foundation
import Security

public struct HostSnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case stopped, starting, running, stopping, blocked, failed }
    public var state: State
    public var message: String
    public var screenAllowed: Bool
    public var inputAllowed: Bool
    public init(state: State = .stopped, message: String = "Sharing is off.", screenAllowed: Bool = false, inputAllowed: Bool = false) {
        self.state = state; self.message = message
        self.screenAllowed = screenAllowed; self.inputAllowed = inputAllowed
    }
}

@objc public protocol HostControlProtocol {
    func status(reply: @escaping (Data) -> Void)
    func requestPermission(_ permission: String, reply: @escaping (Data) -> Void)
    func stopSharing(reply: @escaping () -> Void)
}

/// Pin the installed counterpart, including its cdhash for ad-hoc development builds.
/// No PID-based identity checks or unsigned fallback.
public enum HostPeerIdentity {
    public static func requirement(for bundle: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw HostFailure.message("The installed host app or service has an invalid code signature. Reinstall the signed app.")
        }
        return text as String
    }
}

@MainActor public protocol HostControlClient {
    func status() async throws -> HostSnapshot
    func requestPermission(_ permission: String) async throws -> HostSnapshot
    func stopSharing() async throws
}

@MainActor private final class PendingReply<T> {
    var continuation: CheckedContinuation<T, Error>?
    let connection: NSXPCConnection
    init(_ continuation: CheckedContinuation<T, Error>, connection: NSXPCConnection) {
        self.continuation = continuation; self.connection = connection
    }
    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        continuation.resume(with: result)
    }
}

@MainActor public final class XPCClient: HostControlClient {
    private let helper: URL
    public init(app: URL = Bundle.main.bundleURL) { helper = app.appendingPathComponent(HostIdentity.helperPath) }
    private func request<T>(_ send: @escaping (HostControlProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let requirement = try HostPeerIdentity.requirement(for: helper)
        let connection = NSXPCConnection(machServiceName: HostIdentity.service)
        connection.remoteObjectInterface = NSXPCInterface(with: HostControlProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply(continuation, connection: connection)
            let finish: (Result<T, Error>) -> Void = { result in Task { @MainActor in pending.finish(result) } }
            connection.invalidationHandler = { finish(.failure(HostFailure.message("The host service is unavailable."))) }
            connection.interruptionHandler = { finish(.failure(HostFailure.message("The host service disconnected."))) }
            connection.resume()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ finish(.failure($0)) }) as? HostControlProtocol else {
                finish(.failure(HostFailure.message("Could not connect to the host service."))); return
            }
            send(remote, finish)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                pending.finish(.failure(HostFailure.message("The host service did not respond within 10 seconds.")))
            }
        }
    }
    public func status() async throws -> HostSnapshot {
        try await request { remote, finish in
            remote.status { data in finish(Result { try JSONDecoder().decode(HostSnapshot.self, from: data) }) }
        }
    }
    public func requestPermission(_ permission: String) async throws -> HostSnapshot {
        try await request { remote, finish in
            remote.requestPermission(permission) { data in finish(Result { try JSONDecoder().decode(HostSnapshot.self, from: data) }) }
        }
    }
    public func stopSharing() async throws {
        let _: Bool = try await request { remote, finish in remote.stopSharing { finish(.success(true)) } }
    }
}
