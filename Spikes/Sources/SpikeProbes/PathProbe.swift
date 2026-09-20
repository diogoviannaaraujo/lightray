import Dispatch
import Foundation
import Network
import Synchronization

// NWPathMonitor as the client's trigger for proactive socket replacement.
public func pathProbe() -> Report {
    var rep = Report("NWPathMonitor")
    let monitor = NWPathMonitor()
    let first = Mutex<(UInt64, String)?>(nil)
    let sem = DispatchSemaphore(value: 0)
    let t0 = nowNs()
    monitor.pathUpdateHandler = { path in
        let desc = "status=\(path.status) interfaces=\(path.availableInterfaces.map { "\($0.name)(\($0.type))" }) " +
            "expensive=\(path.isExpensive) constrained=\(path.isConstrained) ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6)"
        let isFirst = first.withLock { f -> Bool in
            guard f == nil else { return false }
            f = (nowNs() - t0, desc)
            return true
        }
        if isFirst { sem.signal() }
    }
    monitor.start(queue: DispatchQueue(label: "path"))
    let ok = sem.wait(timeout: .now() + 3) == .success
    monitor.cancel()
    if ok, let (ns, desc) = first.withLock({ $0 }) {
        rep.add(String(format: "initial update after %.1f ms: ", Double(ns) / 1e6) + desc)
    } else {
        rep.add("no initial path update within 3 s")
    }
    rep.add("path *changes* (Wi-Fi ↔ cellular, VPN up/down) need a device; not exercised here")
    return rep
}
