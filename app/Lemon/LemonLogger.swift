import os

extension Logger {
    static let linear = Logger(subsystem: "com.lemon.app", category: "linear")
    static let worktree = Logger(subsystem: "com.lemon.app", category: "worktree")
    static let orchestrator = Logger(subsystem: "com.lemon.app", category: "orchestrator")
    static let onboarding = Logger(subsystem: "com.lemon.app", category: "onboarding")
}
