import AppKit
import LightrayCore

let usage = """
    usage: lightray-client [<host>[:port]] [options]

    <host>          the host's name or address; [::1]:7373 for IPv6 with a port

    --pair TOKEN    use and remember the token `lightray-host pair` printed
    --pair-file FILE use a token file for this run without saving it or exposing it in argv
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
    --local-cursor  show a local arrow when the host does not capture the cursor
    --screen-id N   place stream windows on this macOS display ID
    --no-stats      hide the performance overlay initially
    --stats         show the performance overlay initially
    --swap-command-control map Command to Windows Control, and Control to Windows key
    --physical-keys use the original physical modifier mapping
    --host-cursor   hide the local pointer
    --no-preferences ignore saved host preferences and do not save changes during this run
    --launcher      open the computer list instead of connecting immediately; default with no host
    --no-host-catalog do not load or save remembered computers

    Local shortcuts: ⌃⌥⌘Q quits; ⌃⌥⌘M toggles statistics; ⌃⌥⌘Esc releases input; ⌃⌥⌘F toggles fullscreen.
    ⌃⌥⌘Tab sends Alt+Tab; ⌃⌥⌘W sends the Windows key. Click video to resume released input.
    ⌃⌥⌘S opens the Lightray session menu. Host preferences are remembered unless --no-preferences is used.
    The Input menu also offers remote shortcuts and Command/Control swapping. Clipboard sync is not included.
    Other keys received by the window go to the host; system-reserved shortcuts may stay on the Mac.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let pairingFile = "client-pairing"
var options = ClientOptions()
var token: String?
var pairingPath: String?
var arguments = Array(CommandLine.arguments.dropFirst())
func value(_ name: String) -> String {
    guard !arguments.isEmpty else { fail("\(name) needs a value\n\n\(usage)") }
    return arguments.removeFirst()
}
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--pair": token = value(argument)
    case "--pair-file": pairingPath = value(argument)
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
    case "--local-cursor": options.localCursor = true
    case "--no-stats": options.showStatistics = false
    case "--stats": options.showStatistics = true
    case "--swap-command-control": options.keyboardMapping = .commandControl
    case "--physical-keys": options.keyboardMapping = .physical
    case "--host-cursor": options.localCursor = false
    case "--no-preferences": options.rememberPreferences = false
    case "--launcher": options.launcher = true
    case "--no-host-catalog": options.rememberHosts = false
    case "--screen-id":
        guard let id = UInt32(value(argument)) else { fail("--screen-id requires a display ID") }
        options.screenID = id
    case "-h", "--help": print(usage); exit(0)
    default:
        guard !argument.hasPrefix("-"), options.host.isEmpty else { fail("unknown option \(argument)\n\n\(usage)") }
        do {
            let target = try ConnectionTarget(argument)
            options.host = target.host; options.port = target.port
        } catch { fail("invalid host address or port") }
    }
}
if options.host.isEmpty { options.launcher = true }

var pairing: Pairing?
if let pairingPath {
    guard token == nil else { fail("use either --pair or --pair-file") }
    guard let text = try? String(contentsOfFile: pairingPath, encoding: .utf8), let parsed = Pairing(token: text) else { fail("cannot read a valid pairing file") }
    pairing = parsed
} else if let token {
    guard let parsed = Pairing(token: token) else { fail("that is not a pairing token") }
    pairing = parsed
    do { try PairingStore.save(parsed, as: pairingFile) } catch { fail("cannot save the pairing: \(error)") }
} else if !options.launcher, let saved = PairingStore.load(pairingFile) {
    pairing = saved
} else if !options.launcher {
    fail("not paired: run `lightray-host pair` on the host and pass its token with --pair")
}

let app = NSApplication.shared
let delegate: NSApplicationDelegate
if options.launcher { delegate = ConnectionLauncher(options: options, pairing: pairing) }
else if let pairing { delegate = ClientApp(options: options, pairing: pairing) }
else { fail("a pairing is required") }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
