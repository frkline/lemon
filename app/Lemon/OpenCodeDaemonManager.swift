import Foundation

actor OpenCodeDaemonManager {
    static let shared = OpenCodeDaemonManager()

    enum EnsureResult: Equatable {
        case ready
        case notInstalled
        case startFailed(String)
        case unhealthy
    }

    private var process: Process?
    private var config: OpenCodeDaemonConfig?

    func ensureRunning(config: OpenCodeDaemonConfig) async -> EnsureResult {
        if await OpenCodeClient(host: config.host, port: config.port).daemonReachable() {
            self.config = config
            return .ready
        }

        guard AgentEngineShell.commandExists("opencode") else {
            return .notInstalled
        }

        stopIfNeeded()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let host = AgentEngineShell.shellQuote(config.host)
        p.arguments = ["-lc", "cd /tmp && opencode serve --hostname \(host) --port \(config.port)"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            process = p
            self.config = config
        } catch {
            return .startFailed(error.localizedDescription)
        }

        for _ in 0 ..< 15 {
            if await OpenCodeClient(host: config.host, port: config.port).daemonReachable() {
                return .ready
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return .unhealthy
    }

    func stopIfNeeded() {
        process?.terminate()
        process = nil
    }
}
