// Lightray iPad probe. Measures what the protocol's resume path and defaults depend on, on a
// real device: lifecycle and socket behaviour across suspension, decoder rebuild cost, HEVC
// format support, AEAD cost, UDP receive throughput and Wi-Fi jitter. Results stream to the Mac
// running tools/probes/apple/ios/host (ProbeHost) and to Documents/probe.log.
//
// Launch arguments: -host <mac-ip>  -auto (run all measurements after launch)
//                   -bgtask (take a background task on backgrounding)  -audio  -pip
import Network
import SwiftUI
import UIKit

@main
struct ProbeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(ProbeModel.shared) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let path = NWPathMonitor()
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var willEnterForegroundAt = 0.0
    private var backgroundCount = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = launchTicks
        let model = ProbeModel.shared
        NetLoop.shared.start()
        NetLoop.shared.post(.setHost(model.host))
        Report.line("LAUNCH \(deviceDescription())")
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            FileLog.shared.write("willResignActive")
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [unowned self] _ in
            didEnterBackground()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [unowned self] _ in
            willEnterForegroundAt = nowMs()
            NetLoop.shared.post(.foreground)
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            guard backgroundCount > 0, willEnterForegroundAt > 0 else { return }
            Report.line(String(format: "FOREGROUND will_enter_to_did_become_active_ms=%.0f", nowMs() - willEnterForegroundAt))
            willEnterForegroundAt = 0
            DecodeProbe.shared.checkAfterForeground()
        }
        path.pathUpdateHandler = { p in
            Report.line("PATH status=\(p.status) interfaces=\(p.availableInterfaces.map { "\($0.name)(\($0.type))" }) expensive=\(p.isExpensive) constrained=\(p.isConstrained)")
        }
        path.start(queue: DispatchQueue(label: "lightray.probe.path"))
        if model.autoRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.runAll() }
        }
        return true
    }

    private func didEnterBackground() {
        backgroundCount += 1
        let app = UIApplication.shared
        if ProbeModel.shared.useBackgroundTask {
            bgTask = app.beginBackgroundTask(withName: "lightray.park") { [unowned self] in
                Report.line(String(format: "BGTASK expired remaining=%.1f", UIApplication.shared.backgroundTimeRemaining))
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        let remaining = app.backgroundTimeRemaining
        NetLoop.shared.post(.background(remaining: remaining > 1e9 ? -1 : remaining))
        FileLog.shared.write("didEnterBackground bgtask=\(bgTask != .invalid) audio=\(AudioKeepAlive.shared.running)")
    }

    private func deviceDescription() -> String {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let d = UIDevice.current
        // Scenes are not connected yet at launch, so fall back to the main screen.
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first ?? UIScreen.main
        let native = "\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height))@\(screen.maximumFramesPerSecond)Hz"
        return "model=\(machine) os=\(d.systemName)_\(d.systemVersion) screen=\(native) cores=\(ProcessInfo.processInfo.activeProcessorCount) lowpower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    static let shared = ProbeModel()

    @Published var host: String
    @Published var lines: [String] = []
    @Published var busy = ""
    @Published var useBackgroundTask: Bool
    @Published var audioKeepAlive = false { didSet { AudioKeepAlive.shared.setEnabled(audioKeepAlive) } }
    @Published var pipKeepAlive = false { didSet { PiPKeepAlive.shared.setEnabled(pipKeepAlive) } }
    let autoRun: Bool

    private var steps: [() -> Void] = []
    private var tputId: UInt32 = 1

    init() {
        let args = ProcessInfo.processInfo.arguments
        var chosen = UserDefaults.standard.string(forKey: "host") ?? "192.168.1.109"
        if let i = args.firstIndex(of: "-host"), i + 1 < args.count {
            chosen = args[i + 1]
            UserDefaults.standard.set(chosen, forKey: "host")
        }
        host = chosen
        useBackgroundTask = args.contains("-bgtask")
        autoRun = args.contains("-auto")
        if args.contains("-audio") { DispatchQueue.main.async { self.audioKeepAlive = true } }
        if args.contains("-pip") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pipKeepAlive = true } }
    }

    func append(_ s: String) {
        lines.insert(s, at: 0)
        if lines.count > 300 { lines.removeLast(lines.count - 300) }
    }

    func applyHost() {
        UserDefaults.standard.set(host, forKey: "host")
        NetLoop.shared.post(.setHost(host))
        Report.line("HOST set to \(host)")
    }

    // Measurements run one after another; each step calls next() when it finishes.
    func runAll() {
        guard busy.isEmpty else { return }
        steps = [runDecodeStep, runCryptoStep] + [50, 100, 200, 400].map { rate in { self.runThroughputStep(rate) } } + [runJitterStep]
        next()
    }
    func runDecode() { guard busy.isEmpty else { return }; steps = [runDecodeStep]; next() }
    func runCrypto() { guard busy.isEmpty else { return }; steps = [runCryptoStep]; next() }
    func runThroughput() { guard busy.isEmpty else { return }; steps = [50, 100, 200, 400].map { rate in { self.runThroughputStep(rate) } }; next() }
    func runJitter() { guard busy.isEmpty else { return }; steps = [runJitterStep]; next() }

    private func next() {
        guard !steps.isEmpty else {
            busy = ""
            Report.line("DONE")
            return
        }
        steps.removeFirst()()
    }

    private func runDecodeStep() {
        busy = "Decoding…"
        DecodeProbe.shared.run { self.next() }
    }

    private func runCryptoStep() {
        busy = "Crypto…"
        DispatchQueue.global(qos: .userInitiated).async {
            CryptoProbe.run()
            DispatchQueue.main.async { self.next() }
        }
    }

    private func runThroughputStep(_ mbps: Int) {
        busy = "Throughput \(mbps) Mb/s…"
        tputId += 1
        NetLoop.shared.post(.throughput(id: tputId, mbps: mbps, seconds: 3))
    }
    func throughputFinished() { if busy.hasPrefix("Throughput") { next() } }

    private func runJitterStep() {
        busy = "Jitter, 30 s at 1 kHz…"
        NetLoop.shared.post(.jitter(seconds: 30, hz: 1000))
    }
    func jitterFinished() { if busy.hasPrefix("Jitter") { next() } }
}

struct ContentView: View {
    @EnvironmentObject var model: ProbeModel

    var body: some View {
        NavigationStack {
            List {
                Section("Mac running ProbeHost") {
                    HStack {
                        TextField("192.168.1.109", text: $model.host)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                        Button("Set") { model.applyHost() }
                    }
                }
                Section("Measurements") {
                    Button("Run all") { model.runAll() }
                    Button("Decoder and formats") { model.runDecode() }
                    Button("Crypto") { model.runCrypto() }
                    Button("UDP throughput") { model.runThroughput() }
                    Button("Wi-Fi jitter (30 s)") { model.runJitter() }
                    if !model.busy.isEmpty { Text(model.busy).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Background task when backgrounded", isOn: $model.useBackgroundTask)
                    Toggle("Audio keep-alive", isOn: $model.audioKeepAlive)
                    Toggle("Picture-in-picture keep-alive", isOn: $model.pipKeepAlive)
                    PiPLayerView().frame(height: 90)
                } header: {
                    Text("Lifecycle")
                } footer: {
                    Text("Heartbeats go to the Mac every 100 ms. Leave the app, wait, and come back; the report shows what happened to the socket and the decoder.")
                }
                Section("Log") {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Lightray probe")
        }
    }
}
