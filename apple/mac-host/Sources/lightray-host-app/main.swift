import AppKit

@MainActor final class HostApplication: NSObject, NSApplicationDelegate {
    private var sharing: HostSharingController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = HostSharingController()
        sharing = controller
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lightray Host", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lightray Host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
        controller.showWindow(nil)
        Task { await controller.service.refreshAfterUpgrade() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sharing?.showWindow(nil); return true
    }
    // Quitting only closes the settings UI. launchd owns the service.
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = HostApplication()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
