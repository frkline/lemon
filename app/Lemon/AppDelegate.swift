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

                    // Film mode: drive the lifecycle walkthrough for the site's
                    // autoplay loop, then exit. Shares the smoke window + capture.
                    if KeychainStore.isFilmMode {
                        openSmokeWindow(state: state)
                        try? await Task.sleep(for: .milliseconds(800))
                        await SmokeTestDriver(nav: state.nav, orchestrator: state.orchestrator).film()
                        return
                    }

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
                // Poll until the MenuBarExtra NSStatusItem exists, then click it.
                // A single fixed-delay click silently no-ops when the status item
                // hasn't installed yet — so retry (~3s budget) until it lands.
                for _ in 0 ..< 20 {
                    if LemonApp.openMenuBarPopover() { return }
                    try? await Task.sleep(for: .milliseconds(150))
                }
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

            // Match the real MenuBarExtra popover envelope (340pt column, content
            // capped at 620 + header) so smoke screenshots catch popover-height
            // clipping — a too-tall window would hide exactly the bug we screenshot for.
            let hosting = NSHostingView(rootView: content)
            let size = NSSize(width: 360, height: 700)
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
