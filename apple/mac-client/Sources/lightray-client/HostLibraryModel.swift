import Foundation
import LightrayCore
import Observation

struct LocalDisplay: Identifiable, Equatable {
    let id: UInt32
    let uuid: String?
    let name: String
    let maximumFramesPerSecond: Int

    var title: String { "\(name) · up to \(maximumFramesPerSecond) FPS" }
}

struct HostDraft: Identifiable {
    let id = UUID()
    var editingPairingID: UInt64?
    var name = ""
    var address = ""
    var token = ""
    var displayID: UInt32?
    var error: String?

    var isEditing: Bool { editingPairingID != nil }
    var canSubmit: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Pairing(token: token) != nil
    }
}

struct HostConnection {
    let target: ConnectionTarget
    let pairing: Pairing
    let displayID: UInt32?
}

/// Keeps public host metadata separate from credentials, including for isolated CLI runs.
@MainActor @Observable final class HostLibraryModel {
    struct PairingStorage {
        var read: (String) throws -> Pairing = PairingStore.read
        var save: (Pairing, String) throws -> Void = PairingStore.save
        var remove: (String) throws -> Void = PairingStore.remove
    }

    private(set) var hosts: [PairedHost] = []
    private(set) var displays: [LocalDisplay] = []
    private(set) var catalogError = false
    var draft: HostDraft?
    var notice: String?

    @ObservationIgnored private let store: PairedHostsStore
    @ObservationIgnored private let pairings: PairingStorage
    @ObservationIgnored private let rememberHosts: Bool
    @ObservationIgnored private let preferredDisplayID: UInt32?
    @ObservationIgnored private var temporaryPairings: [UInt64: Pairing] = [:]

    init(options: ClientOptions, store: PairedHostsStore = PairedHostsStore(),
         pairings: PairingStorage = PairingStorage()) {
        self.store = store
        self.pairings = pairings
        rememberHosts = options.rememberHosts
        preferredDisplayID = options.screenID
        if options.rememberHosts {
            do { hosts = try store.load() }
            catch {
                catalogError = true
                notice = "The saved host list could not be loaded. You can still add hosts for this session. Your existing list will be preserved."
            }
        }
    }

    var canRemember: Bool { rememberHosts && !catalogError }
    private var defaultDisplayID: UInt32? {
        displays.first(where: { $0.id == preferredDisplayID })?.id ?? displays.first?.id
    }

    func updateDisplays(_ displays: [LocalDisplay]) {
        self.displays = displays
        if let selected = draft?.displayID, !displays.contains(where: { $0.id == selected }) {
            draft?.displayID = defaultDisplayID
            draft?.error = "The selected display was disconnected. Using an available display."
        }
    }

    func addHost(address: String = "", pairing: Pairing? = nil) {
        draft = HostDraft(address: address, token: pairing?.token ?? "", displayID: defaultDisplayID)
    }

    func editHost(_ host: PairedHost) {
        var value = HostDraft(editingPairingID: host.pairingID, name: host.name,
                              address: host.address, displayID: displayID(for: host))
        do { value.token = try pairing(for: host).token }
        catch { value.error = "The saved pairing is missing or invalid. Paste the pairing code or import its file again." }
        draft = value
    }

    /// A draft is committed only after both its address and complete catalog validate.
    func saveHost(_ value: HostDraft) -> Bool {
        do {
            let target = try ConnectionTarget(value.address)
            guard let pairing = Pairing(token: value.token) else {
                draft?.error = "Paste a complete pairing code beginning with lr1-, or import a pairing file."
                return false
            }
            if let original = value.editingPairingID, original != pairing.id {
                draft?.error = "This code belongs to a different host. Add it as a new host instead."
                return false
            }
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = displays.first { $0.id == value.displayID }
            let host = PairedHost(pairingID: pairing.id, name: name.isEmpty ? target.host : name,
                                  address: target.address, displayUUID: display?.uuid)
            var updated = hosts
            if let index = updated.firstIndex(where: { $0.pairingID == host.pairingID }) { updated[index] = host }
            else { updated.append(host) }
            try store.validate(updated)
            if canRemember {
                try pairings.save(pairing, host.pairingFileName)
                try store.save(updated)
            } else {
                temporaryPairings[host.pairingID] = pairing
            }
            hosts = updated
            draft = nil
            return true
        } catch ConnectionTarget.ParseError.invalidPort {
            draft?.error = "Use a port between 1 and 65535, for example 192.168.1.2:7373."
        } catch ConnectionTarget.ParseError.invalidHost {
            draft?.error = "Enter an IP address or hostname, without a URL or spaces."
        } catch PairedHostsStore.StoreError.invalidRecord {
            draft?.error = "Use a host name of at most 100 bytes and keep at most 32 hosts."
        } catch {
            draft?.error = "The host could not be saved. Check that this Mac can save its pairing file and try again."
        }
        return false
    }

    func connection(for host: PairedHost) -> HostConnection? {
        do {
            let target = try ConnectionTarget(host.address)
            let pairing = try pairing(for: host)
            if let uuid = host.displayUUID, !displays.contains(where: { $0.uuid == uuid }) {
                notice = "The saved display is unavailable. The session will open on an available display."
            }
            return HostConnection(target: target, pairing: pairing, displayID: displayID(for: host))
        } catch {
            editHost(host)
            return nil
        }
    }

    func forgetHost(_ host: PairedHost) {
        do {
            let updated = hosts.filter { $0.pairingID != host.pairingID }
            if canRemember {
                try store.validate(updated)
                try pairings.remove(host.pairingFileName)
                try store.save(updated)
            }
            temporaryPairings[host.pairingID] = nil
            hosts = updated
            notice = "Host forgotten on this Mac. Access can be revoked separately on the host."
        } catch { notice = "The host could not be removed. The saved list was preserved." }
    }

    private func pairing(for host: PairedHost) throws -> Pairing {
        let pairing: Pairing
        if let temporary = temporaryPairings[host.pairingID] { pairing = temporary }
        else { pairing = try pairings.read(host.pairingFileName) }
        guard pairing.id == host.pairingID else { throw PairingStore.StoreError.invalidPairing }
        return pairing
    }

    private func displayID(for host: PairedHost) -> UInt32? {
        displays.first(where: { $0.uuid != nil && $0.uuid == host.displayUUID })?.id ?? defaultDisplayID
    }
}
