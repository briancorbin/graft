import ArgumentParser
import Foundation
import GraftCore

/// `graft doctor` — verify the whole GitHub App auth chain against the real API
/// without booting a VM: read key → sign JWT → find installation → mint token →
/// create a probe JIT runner → delete it. Leaves no trace on the org.
///
/// Runs straight from flags (`--app-id` + `--target`) with no config file, or
/// against the config's pools when those are omitted.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Verify the GitHub App auth chain end-to-end (no VM boot)."
    )

    @Option(name: .long, help: "GitHub App ID to check (skips the config file; needs --target too).")
    var appId: Int?

    @Option(name: .long, help: "Where runners register: 'org:NAME' or 'repo:OWNER/NAME' (with --app-id).")
    var target: String?

    @Option(name: .long, help: "Runner group id for the probe runner (default 1).")
    var runnerGroupId: Int = 1

    @Option(name: .shortAndLong, help: "Config path (used when --app-id/--target are omitted).")
    var config: String?

    @Option(name: .long, help: "Only check this pool from the config (default: all pools).")
    var pool: String?

    @Flag(help: "Read the key from the system keychain instead of login.")
    var system = false

    @Flag(help: "Stop after minting a token — don't create/delete a probe runner.")
    var noProbe = false

    func run() async throws {
        let pools: [PoolConfig]
        let scope: KeychainScope

        if let appId, let target {
            pools = [PoolConfig(
                name: "cli", image: "-", os: .macOS, count: 0,
                github: GitHubConfig(appId: appId, target: target, runnerGroupId: runnerGroupId)
            )]
            scope = system ? .system : .login
        } else if appId != nil || target != nil {
            throw GraftError("pass BOTH --app-id and --target, or neither (to use the config file)")
        } else {
            let path = GraftConfig.resolvePath(explicit: config)
            let cfg = try GraftConfig.load(from: path)
            let filtered = pool.map { name in cfg.pools.filter { $0.name == name } } ?? cfg.pools
            guard !filtered.isEmpty else {
                throw GraftError(pool.map { "no pool named '\($0)'" } ?? "no pools in config")
            }
            pools = filtered
            scope = system ? .system : (KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login)
        }

        let secrets = KeychainSecretStore(scope: scope)

        func ok(_ message: String) { print("  ✓ \(message)") }
        func fail(_ step: String, _ error: Error) { printErr("  ✗ \(step): \(error)") }

        var failed = false
        for pool in pools {
            print("── app \(pool.github.appId), \(pool.github.target) ──")
            let client = GitHubAppClient(appID: pool.github.appId, secrets: secrets)

            let parsedTarget: GitHubTarget
            do { parsedTarget = try pool.github.parsedTarget() }
            catch { fail("parse target", error); failed = true; continue }

            do { _ = try await client.makeAppJWT(); ok("read key from \(scope.rawValue) keychain + signed App JWT") }
            catch { fail("sign App JWT", error); failed = true; continue }

            do {
                let id = try await client.installationID(for: parsedTarget)
                ok("found App installation (#\(id))")
            } catch { fail("discover installation", error); failed = true; continue }

            do { _ = try await client.installationAccessToken(for: parsedTarget); ok("minted installation access token") }
            catch { fail("mint installation token", error); failed = true; continue }

            if noProbe { continue }

            let probeName = "graft-doctor-" + UUID().uuidString.prefix(8).lowercased()
            do {
                let runner = try await client.generateJITRunner(pool: pool, runnerName: probeName)
                ok("generated JIT config (runner #\(runner.runnerID), \(runner.encodedConfig.count)-byte blob)")
                do {
                    try await client.deleteRunner(id: runner.runnerID, target: parsedTarget)
                    ok("deleted probe runner #\(runner.runnerID)")
                } catch {
                    fail("delete probe runner #\(runner.runnerID) — remove it manually in GitHub", error)
                    failed = true
                }
            } catch { fail("generate JIT config", error); failed = true }
        }

        if failed { throw ExitCode.failure }
        print("\nall checks passed ✓  — GitHub App auth is wired correctly")
    }
}
