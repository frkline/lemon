import Foundation
import Security

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore(inMemory: false)

    // Pass --mock to enable fake-data UI mode (no Linear account needed).
    static let isMockMode: Bool = ProcessInfo.processInfo.arguments.contains("--mock")

    // Pass --smoke-test (alongside --mock) to auto-navigate and screenshot all UI states.
    static let isSmokeTesting: Bool = ProcessInfo.processInfo.arguments.contains("--smoke-test")

    // Detected automatically when launched by XCTest — suppresses Keychain dialogs.
    static let isTestRun: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // non-nil = fully in-memory (tests or mock)
    private var memory: [String: String]?

    private init(inMemory: Bool) {
        self.memory = inMemory ? [:] : nil
    }

    static func makeForTesting() -> KeychainStore {
        KeychainStore(inMemory: true)
    }

    // MARK: - Convenience accessors

    // Only the API key lives in Keychain (it's a secret).
    // userId and workspaceConfig are non-sensitive and stored in UserDefaults.

    var linearApiKey: String {
        get {
            if memory != nil { return memory?["linearApiKey"] ?? "" }
            if Self.isTestRun || Self.isMockMode { return "" }
            return readKeychain("lemon-linear-key") ?? ""
        }
        set {
            if memory != nil { memory?["linearApiKey"] = newValue; return }
            if Self.isTestRun || Self.isMockMode { return }
            writeKeychain("lemon-linear-key", value: newValue)
        }
    }

    var linearUserId: String {
        get {
            if memory != nil { return memory?["linearUserId"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-linear-user-id") ?? ""
        }
        set {
            if memory != nil { memory?["linearUserId"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-linear-user-id")
        }
    }

    var workspaceConfig: String {
        get {
            if memory != nil { return memory?["workspaceConfig"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-workspace-config") ?? ""
        }
        set {
            if memory != nil { memory?["workspaceConfig"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-workspace-config")
        }
    }

    var isConfigured: Bool {
        if Self.isMockMode { return true }
        // Real Keychain store in test mode: always false to prevent the Keychain dialog
        // when there's no user to click it. In-memory stores (makeForTesting) are unaffected.
        if memory == nil && Self.isTestRun { return false }
        guard !linearApiKey.isEmpty, !workspaceRepos.isEmpty else { return false }
        // Local AI is required AND its files must still exist on disk. Without
        // the disk-existence check, a user who upgraded across a dirName
        // change (or deleted ~/Library/Application Support/Lemon/Models) would
        // keep aiEnabled=true and slip into the main app with a broken model.
        let fm = FileManager.default
        return aiEnabled
            && !modelPath.isEmpty
            && fm.fileExists(atPath: modelPath + "/config.json")
            && !swiftLMPath.isEmpty
            && fm.isExecutableFile(atPath: swiftLMPath)
    }

    // MARK: - Workspace repos helpers

    var workspaceRepos: [WorkspaceRepo] {
        guard let data = workspaceConfig.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WorkspaceRepo].self, from: data)) ?? []
    }

    func saveWorkspaceRepos(_ repos: [WorkspaceRepo]) {
        guard let data = try? JSONEncoder().encode(repos),
              let json = String(data: data, encoding: .utf8) else { return }
        workspaceConfig = json
    }

    func repoFor(issuePrefix: String) -> WorkspaceRepo? {
        workspaceRepos.first { $0.issuePrefix.lowercased() == issuePrefix.lowercased() }
    }

    // MARK: - Local AI config (UserDefaults, non-sensitive)

    var swiftLMPath: String {
        get {
            if memory != nil { return memory?["swiftLMPath"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-swiftlm-path") ?? ""
        }
        set {
            if memory != nil { memory?["swiftLMPath"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-swiftlm-path")
        }
    }

    var modelPath: String {
        get {
            if memory != nil { return memory?["modelPath"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-gemma-model-path") ?? ""
        }
        set {
            if memory != nil { memory?["modelPath"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-gemma-model-path")
        }
    }

    var aiEnabled: Bool {
        get {
            if memory != nil { return memory?["aiEnabled"] == "1" }
            return UserDefaults.standard.bool(forKey: "lemon-ai-enabled")
        }
        set {
            if memory != nil { memory?["aiEnabled"] = newValue ? "1" : "0"; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-ai-enabled")
        }
    }

    // MARK: - Legacy write shim (called from onboarding finish())

    @discardableResult
    func write(_ key: LegacyKey, value: String) -> Bool {
        switch key {
        case .linearApiKey:    linearApiKey = value;    return true
        case .linearUserId:    linearUserId = value;    return true
        case .workspaceConfig: workspaceConfig = value; return true
        }
    }

    // Keys still referenced in OnboardingView.finish()
    enum LegacyKey {
        case linearApiKey, linearUserId, workspaceConfig
    }

    // MARK: - Keychain (API key only)

    func deleteAll() {
        if memory != nil { memory = [:]; return }
        SecItemDelete([kSecClass: kSecClassGenericPassword,
                       kSecAttrService: "lemon-linear-key"] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "lemon-linear-user-id")
        UserDefaults.standard.removeObject(forKey: "lemon-workspace-config")
        UserDefaults.standard.removeObject(forKey: "lemon-swiftlm-path")
        UserDefaults.standard.removeObject(forKey: "lemon-gemma-model-path")
        UserDefaults.standard.removeObject(forKey: "lemon-ai-enabled")
    }

    private func readKeychain(_ service: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(_ service: String, value: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
