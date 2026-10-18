import Foundation
import LightrayCore

/// One device paired with this host. Each has a pairing of its own, so it can be listed and
/// revoked alone. A new device waits: its code works only until its first connection or until it
/// expires, and the device is paired once that connection is made.
public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt64
    public var name: String
    public let key: Bytes
    public let created: Date
    /// When the device first connected; nil while the host waits for it.
    public var paired: Date?
    /// Until when a waiting code is accepted; nil once paired.
    public var expires: Date?
    public var lastConnected: Date?
    /// The one code every device shared before pairings were per device.
    public var shared = false

    public var pairing: Pairing { Pairing(id: id, psk: key) }
    public var isWaiting: Bool { paired == nil }
    public var hexID: String { String(format: "%016llx", id) }

    /// Whether the host accepts this device's code at `now`.
    public func accepts(at now: Date) -> Bool { paired != nil || (expires.map { now < $0 } ?? false) }

    init(pairing: Pairing, name: String, created: Date, expires: Date?) {
        id = pairing.id; key = pairing.psk
        self.name = name; self.created = created; self.expires = expires
    }

    private enum CodingKeys: String, CodingKey { case id, name, key, created, paired, expires, lastConnected, shared }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = UInt64(try values.decode(String.self, forKey: .id), radix: 16),
              let key = Bytes(hex: try values.decode(String.self, forKey: .key)), key.count == 32 else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: values, debugDescription: "Invalid pairing")
        }
        self.id = id; self.key = key
        name = try values.decode(String.self, forKey: .name)
        created = try values.decode(Date.self, forKey: .created)
        paired = try values.decodeIfPresent(Date.self, forKey: .paired)
        expires = try values.decodeIfPresent(Date.self, forKey: .expires)
        lastConnected = try values.decodeIfPresent(Date.self, forKey: .lastConnected)
        shared = try values.decodeIfPresent(Bool.self, forKey: .shared) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hexID, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(key.hex, forKey: .key)
        try values.encode(created, forKey: .created)
        try values.encodeIfPresent(paired, forKey: .paired)
        try values.encodeIfPresent(expires, forKey: .expires)
        try values.encodeIfPresent(lastConnected, forKey: .lastConnected)
        if shared { try values.encode(true, forKey: .shared) }
    }
}

/// The devices paired with this host, in `Host/devices.json` beside the settings: a private
/// directory and an owner-only file. The settings app, the service and the CLI all write it, so
/// every change is a read-modify-write under an exclusive lock on `Host/devices.lock`.
public struct PairedDeviceStore: Sendable {
    public static let waitingLifetime: TimeInterval = 10 * 60
    public static let sharedName = "Earlier pairing code"

    public let directory: URL
    /// The single code of earlier versions, imported once as the shared device.
    public let legacy: URL
    public var url: URL { directory.appendingPathComponent("devices.json") }
    var lockURL: URL { directory.appendingPathComponent("devices.lock") }

    public init(directory: URL = PairingStore.directory.appendingPathComponent("Host", isDirectory: true),
                legacy: URL = URL(fileURLWithPath: PairingStore.path("host-pairing"))) {
        self.directory = directory
        self.legacy = legacy
    }

    private struct File: Codable {
        var version = 1
        var devices: [PairedDevice]
    }

    /// Every device, waiting ones included. Reads without the lock: writes replace the file whole.
    public func load() throws -> [PairedDevice] {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            return manager.fileExists(atPath: legacy.path) ? try modify { _ in } : []
        }
        return try decode(Data(contentsOf: url))
    }

    /// Changes the list under the lock and returns it. Waiting devices whose code expired are
    /// dropped after `change` runs, so a connection made just before expiry still pairs.
    @discardableResult
    public func modify(_ change: (inout [PairedDevice]) throws -> Void) throws -> [PairedDevice] {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lock = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw HostFailure.message("Could not open the paired devices lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw HostFailure.message("Could not lock the paired devices.") }

        var devices: [PairedDevice]
        var imported = false
        if manager.fileExists(atPath: url.path) {
            devices = try decode(Data(contentsOf: url))
        } else if let device = importLegacy() {
            devices = [device]; imported = true
        } else {
            devices = []
        }
        try change(&devices)
        let now = Date()
        devices.removeAll { $0.isWaiting && !$0.accepts(at: now) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(devices: devices)).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // The code now lives in devices.json; a copy left behind would outlive its revocation.
        if imported { try? manager.removeItem(at: legacy) }
        return devices
    }

    /// Adds a device the host waits for, with a new code.
    public func addWaiting(name: String, lifetime: TimeInterval = waitingLifetime) throws -> PairedDevice {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostFailure.message("Enter a name for the device.") }
        guard name.count <= 60 else { throw HostFailure.message("Use a device name of at most 60 characters.") }
        let now = Date()
        var device: PairedDevice!
        try modify { devices in
            var pairing = Pairing.generate()
            while devices.contains(where: { $0.id == pairing.id }) { pairing = Pairing.generate() }
            device = PairedDevice(pairing: pairing, name: name, created: now, expires: now + lifetime)
            devices.append(device)
        }
        return device
    }

    /// Revokes a device: its code stops working, and a running host disconnects it.
    public func remove(id: UInt64) throws {
        try modify { $0.removeAll { $0.id == id } }
    }

    /// Withdraws a code the host still waits for; a device that already connected stays.
    public func removeWaiting(id: UInt64) throws {
        try modify { $0.removeAll { $0.id == id && $0.isWaiting } }
    }

    /// Records a completed handshake: a waiting device becomes paired. A revoked one stays gone.
    public func markConnected(id: UInt64, at time: Date = Date()) throws {
        try modify { devices in
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
            if devices[index].paired == nil { devices[index].paired = time }
            devices[index].expires = nil
            devices[index].lastConnected = time
        }
    }

    private func decode(_ data: Data) throws -> [PairedDevice] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: File
        do { file = try decoder.decode(File.self, from: data) }
        catch { throw HostFailure.message("The paired devices file is damaged. It was preserved.") }
        guard file.version == 1 else { throw HostFailure.message("Unsupported paired devices version. The file was preserved.") }
        return file.devices
    }

    private func importLegacy() -> PairedDevice? {
        guard let text = try? String(contentsOf: legacy, encoding: .utf8), let pairing = Pairing(token: text) else { return nil }
        let created = (try? legacy.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var device = PairedDevice(pairing: pairing, name: Self.sharedName, created: created, expires: nil)
        device.paired = created
        device.shared = true
        return device
    }
}

/// A running host's view of the store. It answers key lookups from memory, rereads the file when
/// it changes, and records connections on a queue of its own, so a handshake never waits on
/// another process holding the lock.
public final class StoredPairings: @unchecked Sendable {
    public let store: PairedDeviceStore
    private let lock = NSLock()
    private let writes = DispatchQueue(label: "lightray.host.pairings", qos: .utility)
    private var devices: [UInt64: PairedDevice] = [:]
    private var loaded: FileStamp?

    /// Every write replaces the file, so a new inode marks a change even within one timestamp.
    private struct FileStamp: Equatable { let inode: UInt64; let seconds: Int; let nanoseconds: Int }

    public init(store: PairedDeviceStore = PairedDeviceStore()) {
        self.store = store
        _ = refresh()
    }

    /// The devices as last read. A damaged file reads as none, so no device can connect.
    public var all: [PairedDevice] { lock.withLock { Array(devices.values) } }

    public func key(for id: UInt64) -> Bytes? {
        lock.withLock {
            guard let device = devices[id], device.accepts(at: Date()) else { return nil }
            return device.key
        }
    }

    /// Rereads the store if its file changed; true when it did.
    public func refresh() -> Bool {
        let before = stamp()
        let importing = before == nil && FileManager.default.fileExists(atPath: store.legacy.path)
        guard importing || lock.withLock({ before != loaded }) else { return false }
        var list: [PairedDevice] = []
        do { list = try store.load() } catch {
            log("paired devices could not be read, so no device can connect: \(error.localizedDescription)")
        }
        lock.withLock {
            devices = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // The stamp from before the read: a write during it is picked up at the next refresh.
            loaded = before
        }
        return true
    }

    /// A device completed a handshake: it counts as paired now, and the store learns it shortly.
    public func connected(_ id: UInt64) {
        let now = Date()
        lock.withLock {
            guard var device = devices[id] else { return }
            if device.paired == nil { device.paired = now }
            device.expires = nil
            device.lastConnected = now
            devices[id] = device
        }
        writes.async { [store] in
            do { try store.markConnected(id: id, at: now) }
            catch { log("could not record the connection of device \(String(format: "%016llx", id)): \(error.localizedDescription)") }
        }
    }

    /// Waits for recorded connections to reach the file.
    public func flush() { writes.sync {} }

    private func stamp() -> FileStamp? {
        var info = stat()
        guard stat(store.url.path, &info) == 0 else { return nil }
        return FileStamp(inode: UInt64(info.st_ino), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}
