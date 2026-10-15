import SwiftUI
import UIKit

@main
struct LightrayApp: App {
    @State private var session = ClientSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    session.suspend()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    session.foreground()
                }
        }
    }
}
