import ApplicationServices
import CoreGraphics
import Foundation
import LightrayCore
import LightrayHostRuntime
import LightrayHostSupport
import AppKit

if CommandLine.arguments.contains("--service") {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let service = HostAgent()
        application.delegate = service
        application.setActivationPolicy(.accessory)
        application.run()
    }
    exit(0)
}

let usage = """
    usage: lightray-host [options]
           lightray-host pair NAME [--minutes N]
           lightray-host devices
           lightray-host revoke ID|NAME

    pair            add a device and print its own pairing code, for lightray-client --pair. A
                    running host accepts the code until the device first connects, which pairs
                    it, or for N minutes (default 10)
    devices         list the paired devices and the codes still waiting for theirs
    revoke          remove a device: its code stops working, and a running host disconnects it

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
    --warm S        idle capture timeout in seconds (default unlimited; 0 disables prewarming)
    --fec PERCENT   Reed–Solomon parity per block of fragments, for clients that offer it; 0 turns
                    it off (default 10)
    --fec-min N     at least N parity fragments per block (default 1); --fec 20 --fec-min 2 is
                    Sunshine's setting
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let devices = PairedDeviceStore()
var arguments = Array(CommandLine.arguments.dropFirst())

func describe(_ date: Date?) -> String {
    date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
}

switch arguments.first {
case "pair":
    arguments.removeFirst()
    var minutes = PairedDeviceStore.waitingLifetime / 60
    if let index = arguments.firstIndex(of: "--minutes") {
        guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0, value <= 24 * 60 else {
            fail("--minutes takes a number of minutes, at most 1440")
        }
        minutes = value
        arguments.removeSubrange(index...index + 1)
    }
    guard arguments.count == 1 else { fail("usage: lightray-host pair NAME [--minutes N]") }
    do {
        let device = try devices.addWaiting(name: arguments[0], lifetime: minutes * 60)
        FileHandle.standardError.write(Data("""
            Waiting for \(device.name) (\(device.hexID)). A running host accepts this code until the device \
            first connects, or until \(describe(device.expires)).

            """.utf8))
        print(device.pairing.token)
    } catch { fail("cannot add the device: \(error.localizedDescription)") }
    exit(0)
case "devices":
    do {
        let list = try devices.load().sorted { $0.created < $1.created }
        if list.isEmpty { print("no paired devices: add one with `lightray-host pair NAME`") }
        for device in list {
            let state = device.isWaiting ? "waiting until \(describe(device.expires))" : "paired \(describe(device.paired))"
            print("\(device.hexID)  \(device.name)  \(state)  last connected \(describe(device.lastConnected))")
        }
    } catch { fail("cannot read the paired devices: \(error.localizedDescription)") }
    exit(0)
case "revoke":
    guard arguments.count == 2 else { fail("usage: lightray-host revoke ID|NAME") }
    let target = arguments[1]
    do {
        let list = try devices.load()
        let matches = list.filter { $0.hexID == target.lowercased() || $0.name == target }
        guard let device = matches.first else { fail("no device has the ID or name \(target)") }
        guard matches.count == 1 else { fail("\(matches.count) devices are named \(target): revoke one by its ID") }
        try devices.remove(id: device.id)
        print("revoked \(device.name) (\(device.hexID))")
    } catch { fail("cannot revoke the device: \(error.localizedDescription)") }
    exit(0)
default:
    break
}

var options = HostOptions()
var readyFile: String?
var parentPID: Int32?
var parentWatch: DispatchSourceProcess?
func value(_ name: String) -> String {
    guard !arguments.isEmpty else { fail("\(name) needs a value\n\n\(usage)") }
    return arguments.removeFirst()
}
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--ready-file": readyFile = value(argument)
    case "--parent-pid":
        guard let pid = Int32(value(argument)), pid > 1 else { fail("invalid parent process") }
        parentPID = pid
    case "--port": options.port = UInt16(value(argument)) ?? options.port
    case "--fps": options.frameRate = max(1, min(240, Int(value(argument)) ?? 60))
    case "--bitrate": options.bitrate = Int((Double(value(argument)) ?? 20) * 1_000_000)
    case "--scale": options.scale = max(0.1, min(1, Double(value(argument)) ?? 1))
    case "--mtu": options.maxDatagramSize = max(256, min(9000, Int(value(argument)) ?? 1200))
    case "--log-input": options.inputMode = .log
    case "--no-input": options.inputMode = .off
    case "--drop-rate": options.dropRate = Double(value(argument)) ?? 0
    case "--warm":
        guard let seconds = Double(value(argument)), !seconds.isNaN, seconds >= 0 else {
            fail("--warm takes nonnegative seconds or inf")
        }
        options.warmSeconds = seconds
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

let pairings = StoredPairings(store: devices)
if pairings.all.isEmpty {
    log("no paired devices yet: run `lightray-host pair NAME` while this host runs, and give the code to the client")
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

let app = HostApp(options: options, pairings: pairings)
var signalSources: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM] {
    Darwin.signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { Task { await app.stop(); exit(0) } }
    source.resume()
    signalSources.append(source)
}
Task {
    do {
        try await app.run()
        if let parentPID {
            guard getppid() == parentPID else { raise(SIGTERM); return }
            let watch = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
            watch.setEventHandler { raise(SIGTERM) }
            parentWatch = watch
            watch.resume()
            // Cover the parent exiting between the first check and installing the watch.
            if getppid() != parentPID { raise(SIGTERM); return }
        }
        if let readyFile { try Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyFile), options: .atomic) }
    } catch {
        fail("lightray-host: \(error)")
    }
}
// A run loop rather than dispatchMain, so that display reconfiguration callbacks arrive.
RunLoop.main.run()
