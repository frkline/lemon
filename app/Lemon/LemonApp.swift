import SwiftUI

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
            Task { @MainActor in o.start() }
        }
        return o
    }()

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
    }
}
