import AppKit
import SwiftUI

/// AppKit owns the app lifecycle; SwiftUI owns the settings window's contents.
@MainActor final class HostSharingController: NSWindowController {
    let service: HostService
    private let model: HostSettingsModel
    private var statusTimer: Timer?

    init() {
        let service = HostService()
        self.service = service
        model = HostSettingsModel(service: service)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Lightray Host Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 640)
        window.setFrameAutosaveName("LightrayHostSettings")
        let content = NSHostingView(rootView: HostSettingsView(model: model))
        // The window controls its size; grouped forms scroll within the available space.
        content.sizingOptions = []
        window.contentView = content
        model.window = window
        window.center()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { return }
                await self.service.refresh()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await service.refresh() }
    }
}
