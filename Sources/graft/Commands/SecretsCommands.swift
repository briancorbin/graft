import ArgumentParser
import Foundation
import GraftCore

/// `graft secrets …` — manage GitHub App private keys in the macOS Keychain.
/// The PEM never lives on disk; this is how it gets in (and out of) the Keychain.
struct Secrets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Manage GitHub App private keys in the macOS Keychain.",
        subcommands: [Import.self, List.self, Remove.self]
    )
}

/// Login (default) vs. system keychain, shared by all `secrets` subcommands.
struct KeychainScopeOptions: ParsableArguments {
    @Flag(help: "Use the system keychain — for headless `--daemon` hosts. Writing needs sudo.")
    var system = false

    var scope: KeychainScope { system ? .system : .login }
    var store: KeychainSecretStore { KeychainSecretStore(scope: scope) }
}

extension Secrets {
    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import an App private-key PEM into the Keychain (then shred the file)."
        )

        @Option(name: .long, help: "GitHub App ID.")
        var appId: Int

        @Option(name: .long, help: "Path to the App private-key .pem.")
        var pem: String

        @OptionGroup var keychain: KeychainScopeOptions

        func run() async throws {
            let path = (pem as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw GraftError("can't read PEM at \(path)")
            }
            try PrivateKeyValidator.validate(pem: contents)
            try keychain.store.store(pem: contents, forAppID: appId)
            printErr("✓ stored key for app \(appId) in the \(keychain.scope.rawValue) keychain")
            printErr("  now shred the file:  rm -P \(path)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List App IDs with a stored key.")

        @OptionGroup var keychain: KeychainScopeOptions

        func run() throws {
            let ids = try keychain.store.storedAppIDs()
            guard !ids.isEmpty else {
                printErr("no keys in the \(keychain.scope.rawValue) keychain")
                return
            }
            for id in ids { print(id) }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a stored key."
        )

        @Option(name: .long, help: "GitHub App ID.")
        var appId: Int

        @OptionGroup var keychain: KeychainScopeOptions

        func run() throws {
            try keychain.store.remove(appID: appId)
            printErr("✓ removed key for app \(appId) from the \(keychain.scope.rawValue) keychain")
        }
    }
}
