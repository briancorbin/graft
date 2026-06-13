import ArgumentParser
import GraftCore

/// `graft runners …` — inspect and clean up the runner registrations Graft has
/// created on GitHub. JIT runners that never ran a job (e.g. killed on shutdown)
/// linger as "offline"; `prune` sweeps those husks. The supervisor now deregisters
/// runners on teardown, so this is mainly a safety net + manual cleanup.
struct Runners: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runners",
        abstract: "List or prune graft's GitHub runner registrations.",
        subcommands: [List.self, Prune.self]
    )
}

extension Runners {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List graft runners on GitHub for a profile's targets.")

        @Option(name: .long, help: "Profile to read targets from (default: active).")
        var profile: String?

        @Flag(help: "Use the system keychain instead of login.")
        var system = false

        func run() async throws {
            let (targets, scope) = try profileTargets(profile: profile, system: system)
            let secrets = KeychainSecretStore(scope: scope)
            for gh in targets {
                let parsed = try gh.parsedTarget()
                let client = GitHubAppClient(appID: gh.appId, secrets: secrets)
                let runners = try await client.listRunners(target: parsed)
                    .filter { $0.name.hasPrefix(LocalTartProvider.namePrefix) }
                print("── app \(gh.appId), \(gh.target) ──")
                if runners.isEmpty { print("  (no graft runners)"); continue }
                for r in runners {
                    print("  \(r.isOffline ? "⚪️ offline" : "🟢 online ")  \(r.name)  #\(r.id)")
                }
            }
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete offline graft runner husks on GitHub.")

        @Option(name: .long, help: "Profile to read targets from (default: active).")
        var profile: String?

        @Flag(help: "Use the system keychain instead of login.")
        var system = false

        @Flag(name: .long, help: "Also remove online runners (dangerous — kills live registrations).")
        var includeOnline = false

        func run() async throws {
            let (targets, scope) = try profileTargets(profile: profile, system: system)
            let secrets = KeychainSecretStore(scope: scope)
            var deleted = 0
            for gh in targets {
                let parsed = try gh.parsedTarget()
                let client = GitHubAppClient(appID: gh.appId, secrets: secrets)
                let husks = try await client.listRunners(target: parsed).filter {
                    $0.name.hasPrefix(LocalTartProvider.namePrefix) && (includeOnline || $0.isOffline)
                }
                guard !husks.isEmpty else {
                    printErr("✓ \(gh.target): nothing to prune")
                    continue
                }
                for r in husks {
                    do {
                        try await client.deleteRunner(id: r.id, target: parsed)
                        deleted += 1
                        printErr("  ✓ removed \(r.name) (#\(r.id))")
                    } catch {
                        printErr("  ✗ \(r.name) (#\(r.id)): \(error)")
                    }
                }
            }
            printErr("pruned \(deleted) runner(s)")
        }
    }
}

/// The distinct (app, target) GitHub configs a profile's pools register against
/// (resolved: each pool's override, else the profile default), plus the keychain scope.
/// Deduped so a target shared by several pools is hit once.
private func profileTargets(profile: String?, system: Bool) throws -> (targets: [GitHubConfig], scope: KeychainScope) {
    let name = try resolveProfileName(profile)
    let cfg = try Profiles.load(name)
    let githubs = cfg.pools.compactMap { cfg.gitHub(for: $0) }
    guard !githubs.isEmpty else { throw GraftError("profile '\(name)' has no GitHub config") }

    var seen = Set<String>()
    let distinct = githubs.filter { seen.insert("\($0.appId)|\($0.target)").inserted }
    let scope: KeychainScope = system ? .system : (KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login)
    return (distinct, scope)
}
