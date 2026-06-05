import SwiftUI
import os

// Small UInt16 helper for the MCP port default — guards against UserDefaults
// returning 0 when the key has never been set.
private extension UInt16 {
    func nonZeroOr(_ fallback: UInt16) -> UInt16 { self == 0 ? fallback : self }
}

private extension Int {
    var asUInt16: UInt16 {
        guard self >= 0 && self <= Int(UInt16.max) else { return 0 }
        return UInt16(self)
    }
}

@main
struct LemonApp: App {
    // AppDelegate is always installed — in DEBUG it boots smoke-test mode;
    // in Release it pops the menu-bar popover on first launch so the
    // wizard is visible without the user having to hunt for the icon.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var orchestrator: Orchestrator = {
        #if DEBUG
        if KeychainStore.isMockMode { return MockAppState.shared.orchestrator }
        #endif
        let o = Orchestrator()
        // Start polling at launch when already configured — otherwise polling
        // only kicked in once the user opened the popover, which meant Lemon
        // would silently miss 🍋 issues at app startup. start() is idempotent
        // so the .task on PopoverView below is harmless redundancy.
        if KeychainStore.shared.isConfigured {
            Task { @MainActor in
                o.start()
                LemonApp.startMCPServerIfRequested(orchestrator: o)
            }
        }
        return o
    }()

    // Bring up the MCP server when the user opted in — either via the
    // Settings toggle (lemon-mcp-enabled UserDefault) or by setting
    // LEMON_ENABLE_MCP=1 in the launch environment. The env var wins, so
    // power users can flip the server on for one launch without persisting.
    @MainActor
    static func startMCPServerIfRequested(orchestrator: Orchestrator) {
        let env = ProcessInfo.processInfo.environment
        let envOn = ["1", "true", "yes", "on"].contains((env["LEMON_ENABLE_MCP"] ?? "").lowercased())
        let defaultsOn = UserDefaults.standard.bool(forKey: "lemon-mcp-enabled")
        guard envOn || defaultsOn else { return }
        let port = UserDefaults.standard.integer(forKey: "lemon-mcp-port")
            .asUInt16
            .nonZeroOr(LemonMCPServer.defaultPort)
        do {
            try LemonMCPServer.shared.start(port: port)
            LemonMCPTools.registerAll(server: LemonMCPServer.shared,
                                      orchestrator: orchestrator)
        } catch {
            Logger.orchestrator.error("MCP server failed to start on \(port): \(error.localizedDescription)")
        }
    }

    @State private var nav: AppNavigation = {
        #if DEBUG
        if KeychainStore.isMockMode { return MockAppState.shared.nav }
        #endif
        return AppNavigation()
    }()

    @State private var onboardingComplete: Bool = KeychainStore.shared.isConfigured

    var body: some Scene {
        MenuBarExtra {
            Group {
                if onboardingComplete {
                    PopoverView()
                        .environment(orchestrator)
                        .environment(nav)
                        .task {
                            guard !KeychainStore.isMockMode else { return }
                            orchestrator.start()
                        }
                } else {
                    OnboardingView(isComplete: $onboardingComplete)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .lemonRerunSetup)) { _ in
                onboardingComplete = false
                // Re-running setup pops the menu-bar popover open so the
                // user lands in the wizard immediately, in the same
                // surface they'll use once configured.
                LemonApp.openMenuBarPopover()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                LocalLLM.shared.stop()
            }
            .onChange(of: onboardingComplete) { _, complete in
                // Wizard just transitioned to complete — orchestrator
                // polling will get kicked by PopoverView's .task on the
                // next render. MCP server isn't tied to that, so fire
                // it here so it comes up alongside the polling loop.
                guard complete else { return }
                LemonApp.startMCPServerIfRequested(orchestrator: orchestrator)
            }
        } label: {
            Image(orchestrator.sessions.active.isEmpty ? "MenuBarIconIdle" : "MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("Lemon")
        }
        .menuBarExtraStyle(.window)
    }

    /// Simulate a click on Lemon's menu bar item so the popover (containing
    /// either the wizard or the configured PopoverView) pops open. Used at
    /// launch when the user isn't configured yet — keeps the wizard in the
    /// same surface they'll meet day-to-day, no separate window. Also
    /// re-used by `.lemonRerunSetup` from Settings.
    @MainActor
    static func openMenuBarPopover() {
        // NSStatusBar doesn't expose its items publicly, so we walk
        // NSApp.windows for the AppKit-side window backing the MenuBarExtra
        // popover. The window has no title, no identifier, and is owned by
        // the system status bar. Its rootView's host view is what gets
        // toggled by clicking the menu bar icon.
        //
        // Strategy: find the NSStatusItem via NSApp.windows → first key
        // window whose level matches statusBar, OR walk the menu-bar
        // status item buttons by hit-testing the system status bar.
        // SwiftUI's MenuBarExtra installs exactly one NSStatusItem in the
        // shared NSStatusBar; we iterate the bar to find it.
        let statusBar = NSStatusBar.system
        // NSStatusBar.system has a private `_statusItems` collection;
        // public API doesn't expose it. Fall back to walking NSApp.windows
        // to find the popover's host window and toggling its visibility.
        if let items = statusBar.value(forKey: "_statusItems") as? [NSStatusItem] {
            for item in items {
                if let button = item.button {
                    button.performClick(nil)
                    return
                }
            }
        }
        // Fallback: activate the app so the menu bar icon is at least
        // visually pulsed; the user can click it themselves.
        NSApp.activate(ignoringOtherApps: true)
    }
}
