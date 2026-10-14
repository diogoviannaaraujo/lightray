import AppKit
import LightrayCore

/// Finder/Dock lifecycle and host controls for the bundled app; CLI launches keep their behavior.
final class DesktopApplication: NSObject, NSApplicationDelegate {
    private let launcher: ConnectionLauncher
    private let sharing: HostSharingController
    private var statusItem: NSStatusItem?
    private let statusText = NSMenuItem(title: "Sharing is off", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "Start Sharing", action: #selector(toggleSharing), keyEquivalent: "")

    init(options: ClientOptions, pairing: Pairing?) {
        launcher = ConnectionLauncher(options: options, pairing: pairing)
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/lightray-host")
        sharing = HostSharingController(executable: executable)
        super.init()
        launcher.keepsRunningAfterWindowClose = true
        launcher.configureApplicationMenu = { [weak self] menu in self?.configureMenu(menu) }
        launcher.onShareThisMac = { [weak self] in self?.showSharing(nil) }
        sharing.onStateChange = { [weak self] in self?.updateStatus() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launcher.applicationDidFinishLaunching(notification)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Lightray")
        let menu = NSMenu()
        menu.addItem(statusText)
        menu.addItem(.separator())
        menu.addItem(action("Open Lightray", #selector(openLightray)))
        menu.addItem(action("Share This Mac…", #selector(showSharing(_:))))
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(action("Quit Lightray", #selector(quit)))
        item.menu = menu
        statusItem = item
        updateStatus()
    }

    private func configureMenu(_ menu: NSMenu) {
        guard let applicationMenu = menu.items.first?.submenu else { return }
        applicationMenu.removeAllItems()
        applicationMenu.addItem(withTitle: "About Lightray", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(action("Share This Mac…", #selector(showSharing(_:)), key: ","))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide Lightray", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(action("Quit Lightray", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateStatus() {
        switch sharing.service.state {
        case .running: statusText.title = "Sharing is on"
        case .starting: statusText.title = "Preparing sharing…"
        case .stopping: statusText.title = "Stopping sharing…"
        case .failed: statusText.title = "Sharing needs attention"
        case .stopped: statusText.title = "Sharing is off"
        }
        toggle.title = sharing.service.isActive ? "Stop Sharing" : "Start Sharing"
        toggle.isEnabled = sharing.service.state != .stopping
        statusItem?.button?.toolTip = "Lightray — \(statusText.title)"
    }

    @objc private func openLightray() { launcher.reopen() }
    @objc private func showSharing(_ sender: Any?) { sharing.showWindow(sender) }
    @objc private func toggleSharing() { sharing.toggleSharing() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.reopen()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard sharing.service.isActive else { return .terminateNow }
        sharing.service.stop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        launcher.applicationWillTerminate(notification)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
