import ApplicationServices
import CoreGraphics
import Foundation
import LightrayMac

let usage = """
    usage: lightray-host [options]
           lightray-host pair [--new]

    pair            print this host's pairing token for lightray-client --pair (--new replaces it)

    --port N        UDP port (default 7373)
    --fps N         frame rate cap (default 60)
    --bitrate N     video bitrate in Mb/s, for each display shown, parity included (default 20)
    --scale X       capture at X times each display's pixel size (default 1)
    --mtu N         largest datagram accepted, 256-9000 (default 1200)
    --log-input     log input messages instead of injecting them
    --no-input      ignore input
    --drop-rate X   drop a fraction X of arriving datagrams, to exercise repair
    --test-pattern WxH
                    offer two synthetic displays of that size instead of the real ones
                    (no permission needed)
    --warm S        keep capture and encoders running S seconds after a session ends (default 300)
    --fec PERCENT   Reed–Solomon parity per block of fragments, for clients that offer it; 0 turns
                    it off (default 10)
    --fec-min N     at least N parity fragments per block (default 1); --fec 20 --fec-min 2 is
                    Sunshine's setting
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let pairingFile = "host-pairing"
var arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "pair" {
    var pairing = PairingStore.load(pairingFile)
    if pairing == nil || arguments.contains("--new") {
        pairing = Pairing.generate()
        do { try PairingStore.save(pairing!, as: pairingFile) } catch { fail("cannot save the pairing: \(error)") }
    }
    print(pairing!.token)
    exit(0)
}

var options = HostOptions()
func value(_ name: String) -> String {
    guard !arguments.isEmpty else { fail("\(name) needs a value\n\n\(usage)") }
    return arguments.removeFirst()
}
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--port": options.port = UInt16(value(argument)) ?? options.port
    case "--fps": options.frameRate = max(1, min(240, Int(value(argument)) ?? 60))
    case "--bitrate": options.bitrate = Int((Double(value(argument)) ?? 20) * 1_000_000)
    case "--scale": options.scale = max(0.1, min(1, Double(value(argument)) ?? 1))
    case "--mtu": options.maxDatagramSize = max(256, min(9000, Int(value(argument)) ?? 1200))
    case "--log-input": options.inputMode = .log
    case "--no-input": options.inputMode = .off
    case "--drop-rate": options.dropRate = Double(value(argument)) ?? 0
    case "--warm": options.warmSeconds = max(0, Double(value(argument)) ?? 300)
    case "--fec": options.fecPercent = max(0, min(200, Int(value(argument)) ?? 10))
    case "--fec-min": options.fecMinParity = max(1, min(64, Int(value(argument)) ?? 1))
    case "--test-pattern":
        let size = value(argument).split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, size[0] >= 16, size[1] >= 16 else { fail("--test-pattern takes WIDTHxHEIGHT") }
        options.testPattern = (size[0], size[1])
    case "-h", "--help": print(usage); exit(0)
    default: fail("unknown option \(argument)\n\n\(usage)")
    }
}

guard let pairing = PairingStore.load(pairingFile) else {
    fail("no pairing yet: run `lightray-host pair` and give the token to the client")
}

if options.testPattern == nil, !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    fail("""
        Screen Recording permission is needed. Grant it to the app you launch lightray-host from
        (System Settings › Privacy & Security › Screen & System Audio Recording), then run it again.
        """)
}
if options.inputMode == .inject {
    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
        log("""
            Accessibility permission is missing, so input cannot be injected. Grant it to the app you \
            launch lightray-host from (System Settings › Privacy & Security › Accessibility) and restart.
            """)
    }
}

let app = HostApp(options: options, pairing: pairing)
Task {
    do {
        try await app.run()
    } catch {
        fail("lightray-host: \(error)")
    }
}
// A run loop rather than dispatchMain, so that display reconfiguration callbacks arrive.
RunLoop.main.run()
