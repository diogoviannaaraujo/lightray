import Foundation

enum HostQuality: String, CaseIterable {
    case balanced, smooth, native

    var title: String {
        switch self {
        case .balanced: return "Balanced · 30 fps · half resolution"
        case .smooth: return "Smooth · 60 fps · half resolution"
        case .native: return "Native resolution · 60 fps"
        }
    }

    var arguments: [String] {
        ["--fps", self == .balanced ? "30" : "60", "--scale", self == .native ? "1" : "0.5"]
    }
}

/// Owns only the helper it launches. All state and callbacks are confined to the main thread.
final class HostService {
    enum State: Equatable {
        case stopped, starting, running, stopping, failed(String)
    }

    private(set) var state: State = .stopped {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?
    var isActive: Bool { process != nil }
    let executable: URL
    let logURL: URL
    private var process: Process?
    private var output: FileHandle?
    private var readinessTimer: Timer?
    private var runDirectory: URL?
    private var stopCompletions: [() -> Void] = []

    init(executable: URL, logURL: URL) {
        self.executable = executable
        self.logURL = logURL
    }

    func start(port: UInt16, quality: HostQuality, allowInput: Bool) {
        guard !isActive, port != 0 else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lightray-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            runDirectory = directory
            let ready = directory.appendingPathComponent("ready")
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: logURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            let output = try FileHandle(forWritingTo: logURL)
            self.output = output
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--port", String(port)] + quality.arguments
                + (allowInput ? [] : ["--no-input"])
                + ["--ready-file", ready.path, "--parent-pid", String(getpid())]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = output
            child.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async { self?.finished(ended) }
            }
            process = child
            state = .starting
            try child.run()
            let deadline = Date().addingTimeInterval(30)
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self, weak child] _ in
                guard let self, let child, self.process === child, self.state == .starting else { return }
                if child.isRunning, FileManager.default.fileExists(atPath: ready.path) {
                    self.readinessTimer?.invalidate()
                    self.readinessTimer = nil
                    self.state = .running
                } else if Date() > deadline {
                    self.stop { [weak self] in
                        self?.state = .failed("Sharing did not become ready within 30 seconds. Check permissions and the host log.")
                    }
                }
            }
            readinessTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            cleanup()
            state = .failed("Could not start sharing: \(error.localizedDescription)")
        }
    }

    func stop(completion: @escaping () -> Void = {}) {
        guard let child = process else { completion(); return }
        stopCompletions.append(completion)
        guard state != .stopping else { return }
        state = .stopping
        readinessTimer?.invalidate()
        readinessTimer = nil
        if child.isRunning { child.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak child] in
            guard let self, let child, self.process === child, child.isRunning else { return }
            // A stalled capture must not keep the app, its socket, or remote input alive on Quit.
            kill(child.processIdentifier, SIGKILL)
        }
    }

    private func finished(_ child: Process) {
        guard process === child else { return }
        let requestedStop = state == .stopping
        let detail = logTail().split(separator: "\n").last.map(String.init) ?? "Check the host log for details."
        cleanup()
        state = requestedStop ? .stopped : .failed("Sharing stopped (\(child.terminationStatus)). \(detail)")
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
    }

    private func cleanup() {
        readinessTimer?.invalidate()
        readinessTimer = nil
        process = nil
        try? output?.close()
        output = nil
        if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
        runDirectory = nil
    }

    private func logTail() -> String {
        guard let file = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? file.close() }
        do {
            let end = try file.seekToEnd()
            try file.seek(toOffset: end > 8192 ? end - 8192 : 0)
            return String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return "" }
    }
}
