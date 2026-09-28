import AppKit
import LightrayMac

let usage = """
    usage: lightray-client <host>[:port] [options]

    <host>          the host's name or address; [::1]:7373 for IPv6 with a port

    --pair TOKEN    use and remember the token `lightray-host pair` printed
    --mtu N         datagram size to propose, 256-9000 (default 1200)
    --drop-rate X   drop a fraction X of arriving datagrams, to exercise repair
    --streams N     show up to N of the host's displays at once (default 4)
    --all-displays  show every display of the host, each in its own window
    --show ID       show the host's display ID (as the host logs it); repeat for more windows,
                    the same ID twice for two windows of one display
    --snapshot FILE write each stream's picture to a PNG 3 s after its first one; streams after
                    the first add -<stream> to the name
    --exit-after S  quit after S seconds
    --no-fec        do not offer FEC; the host then sends no parity

    In a window every key goes to the host, Command shortcuts included. ⌃⌥⌘Q quits. The Displays
    menu shows another of the host's displays in a window of its own, or switches the current one.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let pairingFile = "client-pairing"
var options = ClientOptions()
var token: String?
var arguments = Array(CommandLine.arguments.dropFirst())
func value(_ name: String) -> String {
    guard !arguments.isEmpty else { fail("\(name) needs a value\n\n\(usage)") }
    return arguments.removeFirst()
}
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--pair": token = value(argument)
    case "--mtu": options.maxDatagramSize = max(256, min(9000, Int(value(argument)) ?? 1200))
    case "--drop-rate": options.dropRate = Double(value(argument)) ?? 0
    case "--streams": options.streams = max(1, min(30, Int(value(argument)) ?? 4))
    case "--all-displays": options.allDisplays = true
    case "--show":
        guard let id = UInt32(value(argument)), id != 0 else { fail("--show takes a display id") }
        options.show.append(id)
    case "--snapshot": options.snapshot = value(argument)
    case "--exit-after": options.exitAfter = Double(value(argument))
    case "--no-fec": options.offerFEC = false
    case "-h", "--help": print(usage); exit(0)
    default:
        guard !argument.hasPrefix("-"), options.host.isEmpty else { fail("unknown option \(argument)\n\n\(usage)") }
        // host, host:port, [v6], or [v6]:port.
        if argument.hasPrefix("["), let close = argument.firstIndex(of: "]") {
            options.host = String(argument[argument.index(after: argument.startIndex)..<close])
            let rest = argument[argument.index(after: close)...]
            if rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) { options.port = port }
        } else if argument.filter({ $0 == ":" }).count == 1, let colon = argument.firstIndex(of: ":") {
            options.host = String(argument[..<colon])
            options.port = UInt16(argument[argument.index(after: colon)...]) ?? options.port
        } else {
            options.host = argument
        }
    }
}
guard !options.host.isEmpty else { fail(usage) }

var pairing: Pairing
if let token {
    guard let parsed = Pairing(token: token) else { fail("that is not a pairing token") }
    pairing = parsed
    do { try PairingStore.save(parsed, as: pairingFile) } catch { fail("cannot save the pairing: \(error)") }
} else if let saved = PairingStore.load(pairingFile) {
    pairing = saved
} else {
    fail("not paired: run `lightray-host pair` on the host and pass its token with --pair")
}

let app = NSApplication.shared
let delegate = ClientApp(options: options, pairing: pairing)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
