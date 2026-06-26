import AppKit
import SwiftUI

#if DEBUG
    /// Holds mock orchestrator/nav as singletons so AppDelegate can access them
    /// before any view has appeared. First access must be on the main actor.
    @MainActor
    final class MockAppState {
        static let shared = MockAppState()
        let orchestrator = Orchestrator()
        let nav = AppNavigation()
        private init() {}
    }
#endif

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        #if DEBUG
            if KeychainStore.isMockMode {
                Task { @MainActor in
                    let state = MockAppState.shared
                    state.orchestrator.seedMockSessions()

                    guard KeychainStore.isSmokeTesting else { return }
                    openSmokeWindow(state: state)
                    try? await Task.sleep(for: .milliseconds(800))
                    await SmokeTestDriver(nav: state.nav, orchestrator: state.orchestrator).run()
                }
                return
            }
        #endif

        // Real launch (not mock): if Lemon isn't configured yet, pop the
        // menu-bar popover open automatically so the wizard appears in the
        // surface the user will keep using post-onboarding. No separate
        // window — Lemon stays a menu-bar app end-to-end.
        if !KeychainStore.shared.isConfigured {
            Task { @MainActor in
                // Brief delay so MenuBarExtra has time to install its
                // NSStatusItem before we try to click it.
                try? await Task.sleep(for: .milliseconds(350))
                LemonApp.openMenuBarPopover()
            }
        }
    }

    #if DEBUG
        @MainActor
        private func openSmokeWindow(state: MockAppState) {
            let content = PopoverView()
                .environment(state.orchestrator)
                .environment(state.nav)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            let hosting = NSHostingView(rootView: content)
            let size = NSSize(width: 480, height: 560)
            hosting.frame = NSRect(origin: .zero, size: size)

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false,
            )
            window.title = "Lemon Preview"
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            SmokeWindowHolder.shared.window = window
        }
    #endif
}

#if DEBUG
    @MainActor
    final class SmokeWindowHolder {
        static let shared = SmokeWindowHolder()
        var window: NSWindow?
        private init() {}
    }
#endif
