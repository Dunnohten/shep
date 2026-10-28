import SwiftUI

@main
struct ShepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All UI is AppKit-owned (status item, onboarding window, overlay panel); SwiftUI only hosts views.
        Settings { EmptyView() }
    }
}
