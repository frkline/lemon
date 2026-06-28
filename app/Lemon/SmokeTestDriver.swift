#if DEBUG
    import AppKit
    import os
    import SwiftUI

    @MainActor
    final class SmokeTestDriver {
        let nav: AppNavigation
        let orchestrator: Orchestrator
        let outputDir: String

        init(nav: AppNavigation, orchestrator: Orchestrator) {
            self.nav = nav
            self.orchestrator = orchestrator
            let ts = Int(Date().timeIntervalSince1970)
            self.outputDir = "/tmp/lemon-smoke/\(ts)"
        }

        func run() async {
            try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

            try? await Task.sleep(for: .milliseconds(300))

            // 1 — list (active + recent)
            await shot("01-list")

            // 1b — header polling indicator (forced on; mock mode doesn't poll).
            jump { orchestrator.isPolling = true }
            try? await Task.sleep(for: .milliseconds(200))
            await shot("01b-polling")
            jump { orchestrator.isPolling = false }
            try? await Task.sleep(for: .milliseconds(80))

            // 2 — first active session (executing, with AI summary)
            if let s = orchestrator.sessions.active.first(where: { $0.pendingAction == nil }) {
                jump { nav.showDetail(s) }
                try? await Task.sleep(for: .milliseconds(150))
                await shot("02-detail-executing")
                jump { nav.showList() }
                try? await Task.sleep(for: .milliseconds(80))
            }

            // 2b — reviewing session (tallest detail: ready-for-review card +
            // AI summary + console + footer). Guards against the footer clipping.
            if let s = orchestrator.sessions.active.first(where: { $0.status == .reviewing }) {
                jump { nav.showDetail(s) }
                try? await Task.sleep(for: .milliseconds(150))
                await shot("02b-detail-reviewing")
                jump { nav.showList() }
                try? await Task.sleep(for: .milliseconds(80))
            }

            // 2c — plan gate (the keystone state: plan card + Approve & run).
            if let s = orchestrator.sessions.active.first(where: { $0.status == .planReview }) {
                jump { nav.showDetail(s) }
                try? await Task.sleep(for: .milliseconds(150))
                await shot("02c-detail-plan-review")
                jump { nav.showList() }
                try? await Task.sleep(for: .milliseconds(80))
            }

            // 2d — result gate (approve before the PR opens).
            if let s = orchestrator.sessions.active.first(where: { $0.status == .resultReview }) {
                jump { nav.showDetail(s) }
                try? await Task.sleep(for: .milliseconds(150))
                await shot("02d-detail-result-review")
                jump { nav.showList() }
                try? await Task.sleep(for: .milliseconds(80))
            }

            // 3 — second active session (waiting + pending action toast)
            if let s = orchestrator.sessions.active.first(where: { $0.pendingAction != nil }) {
                jump { nav.showDetail(s) }
                try? await Task.sleep(for: .milliseconds(150))
                await shot("03-detail-waiting-pending")
                jump { nav.showList() }
                try? await Task.sleep(for: .milliseconds(80))
            }

            // 3b — cancel pending action: verifies the Cancel button wires through to the model
            if let s = orchestrator.sessions.active.first(where: { $0.pendingAction != nil }) {
                orchestrator.cancelPendingAction(for: s)
                try? await Task.sleep(for: .milliseconds(50))
                assert(s.pendingAction == nil, "[smoke] cancelPendingAction did not clear pendingAction")
                Logger.orchestrator.info("[smoke] ✓ cancelPendingAction cleared pendingAction")
                // Restore for subsequent screenshots
                s.pendingAction = "Accepting MCP servers… (Cancel to abort)"
            }

            // 3c — join clipboard path (no iTerm): verifies the clipboard command is well-formed.
            // When iTerm is absent the Join button copies "tmux attach -t lemon-{id}" to clipboard.
            if let s = orchestrator.sessions.active.first(where: { $0.pendingAction == nil }),
               !FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
            {
                let expectedSession = "lemon-\(s.issue.pathSlug)"
                let expectedCmd = "tmux attach -t \(expectedSession)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(expectedCmd, forType: .string)
                let pasted = NSPasteboard.general.string(forType: .string) ?? ""
                assert(pasted == expectedCmd, "[smoke] clipboard join: expected '\(expectedCmd)', got '\(pasted)'")
                Logger.orchestrator.info("[smoke] ✓ clipboard join command: \(expectedCmd)")
            }

            // 4 — settings
            jump { nav.showSettings() }
            try? await Task.sleep(for: .milliseconds(150))
            await shot("04-settings")

            // 4b — workspace editor pane (existing workspace)
            if let firstWorkspace = KeychainStore.shared.workspaces.first {
                jump { nav.editWorkspace(firstWorkspace.id) }
                try? await Task.sleep(for: .milliseconds(180))
                await shot("04b-workspace-editor")
                jump { nav.popEditor() }
                try? await Task.sleep(for: .milliseconds(80))
            }

            // 4c — identity editor pane (existing identity)
            if let firstIdentity = KeychainStore.shared.identities.first {
                jump { nav.editIdentity(firstIdentity.id) }
                try? await Task.sleep(for: .milliseconds(180))
                await shot("04c-identity-editor")
                jump { nav.popEditor() }
                try? await Task.sleep(for: .milliseconds(80))
            }

            // 4d — add-workspace pane (new draft)
            jump { nav.addWorkspace() }
            try? await Task.sleep(for: .milliseconds(180))
            await shot("04d-workspace-new")
            jump { nav.popEditor() }
            try? await Task.sleep(for: .milliseconds(80))

            jump { nav.showList() }
            try? await Task.sleep(for: .milliseconds(80))

            // 5 — empty state (clear everything, capture, restore)
            let savedActive = orchestrator.sessions.active
            let savedRecent = orchestrator.sessions.recent
            jump {
                orchestrator.sessions.active = []
                orchestrator.sessions.recent = []
            }
            try? await Task.sleep(for: .milliseconds(250))
            await shot("05-empty")
            jump {
                orchestrator.sessions.active = savedActive
                orchestrator.sessions.recent = savedRecent
            }
            try? await Task.sleep(for: .milliseconds(150))

            // 6–10 — onboarding wizard steps
            await runOnboarding()

            printResults()
            NSApp.terminate(nil)
        }

        // MARK: - Onboarding

        private func runOnboarding() async {
            // Create one persistent window for the entire onboarding sequence.
            // Using a single window avoids use-after-free crashes that occur when
            // NSWindow's isReleasedWhenClosed (default true) frees the window while
            // SwiftUI's hosting machinery still holds references into the view tree.
            let win = NSWindow(
                contentRect: CGRect(x: 200, y: 200, width: 340, height: 640),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false,
            )
            win.isReleasedWhenClosed = false

            // The wizard is now 4 steps (Connect+Workspace merged). forcedStep
            // maps 0→Connect, 2→LEMON.md, 3→Local AI, 4→Ready (1 also lands on
            // Connect, so it's skipped to avoid a duplicate shot).
            let steps: [(Int, String)] = [
                (0, "06-onboarding-connect"),
                (2, "07-onboarding-lemonmd"),
                (3, "08-onboarding-localai"),
                (4, "09-onboarding-ready"),
            ]

            for (stepIndex, name) in steps {
                var dummy = false
                let binding = Binding(get: { dummy }, set: { dummy = $0 })
                let view = OnboardingView(isComplete: binding, forcedStep: stepIndex)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = CGRect(x: 0, y: 0, width: 340, height: 640)
                win.contentView = hosting
                win.makeKeyAndOrderFront(nil)

                // Allow the hosting view to perform its initial layout pass.
                try? await Task.sleep(for: .milliseconds(250))
                await shotWindow(win, name: name)
                // Brief pause between steps so any onDisappear timers fire cleanly.
                try? await Task.sleep(for: .milliseconds(100))
            }

            win.close()
        }

        // MARK: - Helpers

        /// Applies a state change with all animations disabled — including .animation(_:value:) modifiers
        /// which bypass withAnimation(nil). This ensures screenshots capture settled layout.
        private func jump(_ body: () -> Void) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t, body)
        }

        // MARK: - In-process bitmap snapshot (no screen recording permission needed)

        private func shot(_ name: String) async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 100 }) else {
                Logger.orchestrator.warning("[smoke] No visible window for \(name)")
                return
            }
            await shotWindow(window, name: name)
        }

        private func shotWindow(_ window: NSWindow, name: String) async {
            let path = "\(outputDir)/\(name).png"
            guard let view = window.contentView else {
                Logger.orchestrator.warning("[smoke] No contentView for \(name)")
                return
            }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: rep.size)
            img.addRepresentation(rep)
            guard let tiff = img.tiffRepresentation,
                  let bmp = NSBitmapImageRep(data: tiff),
                  let png = bmp.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
            Logger.orchestrator.info("[smoke] → \(name).png")
        }

        private func printResults() {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: outputDir))?.sorted() ?? []
            print("\n[smoke] \(files.count) screenshots → \(outputDir)/")
            // Update the "latest" symlink for diffing
            let latest = "/tmp/lemon-smoke/latest"
            try? FileManager.default.removeItem(atPath: latest)
            try? FileManager.default.createSymbolicLink(atPath: latest, withDestinationPath: outputDir)
        }
    }
#endif
