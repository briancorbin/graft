import Foundation
import Security

/// Reads a GitHub App private key (PEM) at runtime. The read path is all
/// `GitHubAppClient` needs; concrete stores add their own write/list APIs.
/// Mirrors `VMProvider`'s swap philosophy — Keychain now, Vault/1Password later.
public protocol SecretStore: Sendable {
    func privateKeyPEM(forAppID appID: Int) async throws -> String
}

/// Which macOS keychain backs the store.
public enum KeychainScope: String, Sendable, CaseIterable {
    /// The user's login keychain — unlocked by the GUI session. For interactive
    /// `graft run`.
    case login
    /// The system keychain (`/Library/Keychains/System.keychain`) — root-accessible
    /// and unlocked at boot, so a headless `graft run --daemon` can reach it with no
    /// login session. Writing requires sudo.
    case system
}

/// `SecretStore` backed by the macOS Keychain. The PEM is stored as a generic-
/// password item keyed by `service="graft-github-app", account=<appID>`, so it's
/// resolved purely from the App ID already in config — no key path on disk.
public struct KeychainSecretStore: SecretStore {
    public static let service = "graft-github-app"

    public let scope: KeychainScope

    public init(scope: KeychainScope = .login) {
        self.scope = scope
    }

    // MARK: Read (SecretStore)

    public func privateKeyPEM(forAppID appID: Int) async throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: String(appID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        applySearchScope(to: &query)

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let pem = String(data: data, encoding: .utf8) else {
                throw GraftError("keychain item for app \(appID) is not valid UTF-8")
            }
            return pem
        case errSecItemNotFound:
            throw GraftError(
                "no private key in \(scope.rawValue) keychain for app \(appID) — "
                + "run `graft secrets import --app-id \(appID) --pem <path>`"
            )
        default:
            throw keychainError("read", status)
        }
    }

    // MARK: Write / manage (used by `graft secrets`)

    /// Upsert the PEM for an App. Deletes any existing item first so re-importing
    /// is idempotent.
    public func store(pem: String, forAppID appID: Int) throws {
        try remove(appID: appID)
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: String(appID),
            kSecAttrLabel as String: "Graft GitHub App \(appID) private key",
            kSecValueData as String: Data(pem.utf8),
        ]
        applyWriteScope(to: &attributes)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw keychainError("write", status)
        }
    }

    /// Remove the PEM for an App. No-op if absent.
    public func remove(appID: Int) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: String(appID),
        ]
        applySearchScope(to: &query)

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError("delete", status)
        }
    }

    /// App IDs that currently have a key in this keychain.
    public func storedAppIDs() throws -> [Int] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        applySearchScope(to: &query)

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let array = items as? [[String: Any]] else {
            throw keychainError("list", status)
        }
        return array
            .compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(Int.init) }
            .sorted()
    }

    // MARK: Scope plumbing

    // The data-protection keychain can't target file-based login/system keychains,
    // so we use the legacy SecKeychain APIs (deprecated since 10.10 but the only way
    // to address a specific keychain file on macOS). Login uses the default list.

    private func applySearchScope(to query: inout [String: Any]) {
        if let keychain = systemKeychainIfNeeded() {
            query[kSecMatchSearchList as String] = [keychain]
        }
    }

    private func applyWriteScope(to attributes: inout [String: Any]) {
        if let keychain = systemKeychainIfNeeded() {
            attributes[kSecUseKeychain as String] = keychain
        }
    }

    private func systemKeychainIfNeeded() -> SecKeychain? {
        guard scope == .system else { return nil }
        var keychain: SecKeychain?
        // Deprecated API, intentional: the only way to address the system keychain file.
        let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        return status == errSecSuccess ? keychain : nil
    }

    private func keychainError(_ action: String, _ status: OSStatus) -> GraftError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        var message = "keychain \(action) failed: \(detail)"
        if status == errSecAuthFailed && scope == .system {
            message += " (writing the system keychain needs sudo)"
        }
        return GraftError(message)
    }
}
