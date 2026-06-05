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
    #if DEBUG
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

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
                // Re-running setup pops the wizard window back open so the
                // user lands in the right surface immediately.
                NSApp.activate(ignoringOtherApps: true)
                LemonApp.presentOnboardingWindow()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                LocalLLM.shared.stop()
            }
        } label: {
            Image(orchestrator.sessions.active.isEmpty ? "MenuBarIconIdle" : "MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("Lemon")
        }
        .menuBarExtraStyle(.window)

        // Standalone onboarding window — opens automatically at launch when
        // nothing's configured, so the user lands inside the wizard instead
        // of having to discover the menu-bar icon and click into a popover.
        // .defaultLaunchBehavior is evaluated once at process start; the
        // window stays out of the way for already-configured users.
        Window("Welcome to Lemon", id: "lemon-onboarding") {
            OnboardingWindowContents(
                onboardingComplete: $onboardingComplete,
                orchestrator: orchestrator,
                nav: nav
            )
        }
        .defaultSize(width: 520, height: 720)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(
            KeychainStore.shared.isConfigured ? .suppressed : .presented
        )
    }

    /// Called from rerunSetup so the wizard window pops back into view even
    /// if the user closed it during the session.
    @MainActor
    static func presentOnboardingWindow() {
        // The Window-id contract is "lemon-onboarding"; SwiftUI surfaces it
        // via OpenWindowAction inside views. From AppKit space we hit
        // NSApp.windows directly and re-show whichever NSWindow is hosting
        // the SwiftUI surface.
        for window in NSApp.windows where window.identifier?.rawValue == "lemon-onboarding"
            || window.title == "Welcome to Lemon" {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}

/// Hosting content for the standalone onboarding window. Pulled into its own
/// view so we can use @Environment(\.dismissWindow) to close the window
/// once the wizard reports complete.
private struct OnboardingWindowContents: View {
    @Binding var onboardingComplete: Bool
    let orchestrator: Orchestrator
    let nav: AppNavigation
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingView(isComplete: $onboardingComplete)
            .environment(orchestrator)
            .environment(nav)
            .onChange(of: onboardingComplete) { _, complete in
                if complete {
                    // Configured — start the polling loop and dismiss the
                    // wizard window. The popover takes over from here.
                    orchestrator.start()
                    LemonApp.startMCPServerIfRequested(orchestrator: orchestrator)
                    dismissWindow(id: "lemon-onboarding")
                }
            }
    }
}
