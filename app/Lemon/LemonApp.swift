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
        return Orchestrator()
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
