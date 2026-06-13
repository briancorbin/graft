import ArgumentParser
import GraftCore

/// `graft pool …` — flag-driven pool edits on a profile (scripting counterpart to
/// the `graft init` wizard).
struct Pool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pool",
        abstract: "Add, remove, or list pools in a profile.",
        subcommands: [New.self, Add.self, Remove.self, List.self]
    )
}

extension Pool {
    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "new",
            abstract: "Interactively add a pool to a profile (image picked from the machine).",
            aliases: ["create"]
        )

        @Option(name: .long, help: "Profile to edit (default: active). Created if missing.")
        var profile: String?

        @Flag(help: "Use the system keychain for key import (headless hosts).")
        var system = false

        func run() async throws {
            let profileName = profile ?? Profiles.activeName() ?? "default"
            var config = Profiles.exists(profileName)
                ? try Profiles.load(profileName)
                : GraftConfig(provider: .tart, secrets: SecretsConfig())

            let pool = await Wizard.buildPool()
            let replaced = config.pools.contains { $0.name == pool.name }
            config.pools.removeAll { $0.name == pool.name }
            config.pools.append(pool)
            try Profiles.save(config, as: profileName)
            printErr("✓ \(replaced ? "replaced" : "added") pool '\(pool.name)' in profile '\(profileName)'")
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add (or replace) a pool in a profile.")

        @Option(name: .long, help: "Profile to edit (default: active). Created if missing.")
        var profile: String?

        @Option(name: .long, help: "Pool name.")
        var name: String

        @Option(name: .long, help: "Tart image.")
        var image: String

        @Option(name: .long, help: "Guest OS (macos|linux).")
        var os: GuestOS = .macOS

        @Option(name: .long, help: "Number of runners.")
        var count: Int = 2

        @Option(name: .long, help: "Override the profile's GitHub App ID (with --target). Default: inherit the profile.")
        var appId: Int?

        @Option(name: .long, help: "Override the profile's target: org:NAME or repo:OWNER/NAME (with --app-id).")
        var target: String?

        @Option(name: .long, help: "Runner group id for a --app-id/--target override (default 1).")
        var runnerGroupId: Int = 1

        @Option(name: .long, help: "Comma-separated labels (the pool's tags; blank = default).")
        var labels: String?

        @Option(name: .long, parsing: .singleValue, help: "Host cache mount: path | name:path | name:path:ro (repeatable). Prefer :ro for shared caches.")
        var mount: [String] = []

        @Option(name: .long, help: "CPU cores per leaf for this pool's workload (default: backend default).")
        var cpu: Int?

        @Option(name: .long, help: "Memory (MB) per leaf for this pool's workload (default: backend default).")
        var memory: Int?

        func run() throws {
            // Profile may not exist yet — create it on first add.
            let profileName = profile ?? Profiles.activeName() ?? "default"
            var config = Profiles.exists(profileName)
                ? try Profiles.load(profileName)
                : GraftConfig(provider: .tart, secrets: SecretsConfig())

            let labelList = labels?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let mounts = try mount.map { try Mount(spec: $0) }
            // GitHub is profile-level; only build a per-pool override if both halves given.
            let github: GitHubConfig? = (appId != nil && target != nil)
                ? GitHubConfig(appId: appId!, target: target!, runnerGroupId: runnerGroupId)
                : nil

            let pool = PoolConfig(
                name: name, image: image, os: os, count: count,
                github: github, labels: labelList,
                mounts: mounts.isEmpty ? nil : mounts, cpu: cpu, memory: memory
            )
            let replaced = config.pools.contains { $0.name == name }
            config.pools.removeAll { $0.name == name }
            config.pools.append(pool)
            try Profiles.save(config, as: profileName)
            printErr("✓ \(replaced ? "replaced" : "added") pool '\(name)' in profile '\(profileName)'")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a pool from a profile.")

        @Option(name: .long, help: "Profile to edit (default: active).")
        var profile: String?

        @Argument(help: "Pool name.")
        var name: String

        func run() throws {
            let profileName = try resolveProfileName(profile)
            var config = try Profiles.load(profileName)
            guard config.pools.contains(where: { $0.name == name }) else {
                throw GraftError("profile '\(profileName)' has no pool named '\(name)'")
            }
            config.pools.removeAll { $0.name == name }
            try Profiles.save(config, as: profileName)
            printErr("✓ removed pool '\(name)' from profile '\(profileName)'")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List pools in a profile.")

        @Option(name: .long, help: "Profile to list (default: active).")
        var profile: String?

        func run() throws {
            let profileName = try resolveProfileName(profile)
            let config = try Profiles.load(profileName)
            guard !config.pools.isEmpty else {
                printErr("profile '\(profileName)' has no pools")
                return
            }
            for pool in config.pools {
                let gh = config.gitHub(for: pool).map { "app \($0.appId)\t\($0.target)" } ?? "(no github)"
                print("\(pool.name)\t\(pool.os.rawValue)\tx\(pool.count)\t\(pool.image)\t\(gh)")
            }
        }
    }
}
