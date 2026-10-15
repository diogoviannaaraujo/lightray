import AppKit
import LightrayCore

/// Finder/Dock lifecycle for the client. Sharing lives in the independent Host app.
final class DesktopApplication: NSObject, NSApplicationDelegate {
    private let launcher: ConnectionLauncher

    init(options: ClientOptions, pairing: Pairing?) {
        launcher = ConnectionLauncher(options: options, pairing: pairing)
        super.init()
        launcher.keepsRunningAfterWindowClose = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launcher.applicationDidFinishLaunching(notification)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.reopen()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        launcher.applicationWillTerminate(notification)
    }
}
