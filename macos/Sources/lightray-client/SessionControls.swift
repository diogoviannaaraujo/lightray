import AppKit
import LightrayMac

/// Local controls stay outside remote input and remain reachable in full screen.
final class SessionControls: NSViewController {
    private weak var video: VideoView?
    private let statistics = NSButton(checkboxWithTitle: "Show performance statistics", target: nil, action: nil)
    private let mapping = NSButton(checkboxWithTitle: "Use Command for Windows shortcuts", target: nil, action: nil)
    private let cursor = NSButton(checkboxWithTitle: "Show local pointer", target: nil, action: nil)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let resume = NSButton(title: "Resume remote input", target: nil, action: nil)
    private let altTab = NSButton(title: "Send Alt+Tab", target: nil, action: nil)
    private let windowsKey = NSButton(title: "Send Windows key", target: nil, action: nil)

    init(video: VideoView) {
        self.video = video
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        let title = NSTextField(labelWithString: "Lightray")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = NSColor(calibratedRed: 0.15, green: 0.76, blue: 0.86, alpha: 1)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        let explanation = NSTextField(wrappingLabelWithString: "Command becomes Ctrl. Control becomes the Windows key. Right Option remains AltGr when the Windows layout supports it.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        let shortcuts = NSTextField(wrappingLabelWithString: "⌃⌥⌘S session menu\n⌃⌥⌘Esc release input\n⌃⌥⌘F full screen\nClick the video to resume released input.")
        shortcuts.font = .systemFont(ofSize: 12)
        shortcuts.textColor = .secondaryLabelColor
        let saved = NSTextField(wrappingLabelWithString: "Preferences apply to this paired host. Remote shortcut buttons resume input and operate inside Windows.")
        saved.font = .systemFont(ofSize: 12)
        saved.textColor = .secondaryLabelColor
        let fullScreen = NSButton(title: "Toggle full screen", target: self, action: #selector(toggleFullScreen))
        let reset = NSButton(title: "Reset host preferences", target: self, action: #selector(resetPreferences))
        let disconnect = NSButton(title: "Disconnect", target: self, action: #selector(disconnectSession))
        statistics.target = self; statistics.action = #selector(changePreferences)
        mapping.target = self; mapping.action = #selector(changePreferences)
        cursor.target = self; cursor.action = #selector(changePreferences)
        resume.target = self; resume.action = #selector(resumeInput)
        altTab.target = self; altTab.action = #selector(sendAltTab)
        windowsKey.target = self; windowsKey.action = #selector(sendWindowsKey)
        let remote = NSStackView(views: [altTab, windowsKey])
        remote.orientation = .horizontal
        remote.distribution = .fillEqually
        remote.spacing = 8
        let stack = NSStackView(views: [title, summary, statistics, mapping, explanation, cursor, fullScreen, remote, resume, reset, saved, shortcuts, disconnect])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            saved.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            remote.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refresh()
    }

    func refresh() {
        guard isViewLoaded, let video else { return }
        statistics.state = video.statisticsVisible ? .on : .off
        mapping.state = video.keyboardMapping == .commandControl ? .on : .off
        cursor.state = video.localCursor ? .on : .off
        summary.stringValue = "\(video.streamStateText)\n\(video.inputEnabled ? "Remote input enabled" : "Remote input released")"
        resume.isEnabled = video.streamState == .live
        altTab.isEnabled = video.streamState == .live
        windowsKey.isEnabled = video.streamState == .live
    }

    @objc private func changePreferences() {
        var preferences = SessionPreferences()
        preferences.showStatistics = statistics.state == .on
        preferences.keyboardMapping = mapping.state == .on ? .commandControl : .physical
        preferences.localCursor = cursor.state == .on
        video?.onPreferencesChange?(preferences)
        refresh()
    }
    @objc private func resetPreferences() { video?.onResetPreferences?(); refresh() }
    @objc private func resumeInput() { video?.setInputEnabled(true); video?.closeSessionMenu() }
    private func resumeAndSend(_ shortcut: RemoteKeyboard.Shortcut) {
        guard let video, video.streamState == .live else { return }
        video.setInputEnabled(true)
        video.closeSessionMenu()
        video.sendShortcut(shortcut)
    }
    @objc private func sendAltTab() { resumeAndSend(.altTab) }
    @objc private func sendWindowsKey() { resumeAndSend(.windowsKey) }
    @objc private func toggleFullScreen() { video?.closeSessionMenu(); video?.window?.toggleFullScreen(nil) }
    @objc private func disconnectSession() { video?.closeSessionMenu(); video?.onDisconnect?() }
}
