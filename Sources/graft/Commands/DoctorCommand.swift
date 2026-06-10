import ArgumentParser
import Foundation
import GraftCore

/// `graft doctor` — verify the whole GitHub App auth chain against the real API
/// without booting a VM: read key → sign JWT → find installation → mint token →
/// create a probe JIT runner → delete it. Leaves no trace on the org.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Verify the GitHub App auth chain end-to-end (no VM boot)."
    )

    @Option(name: .shortAndLong, help: "Config path (default: $GRAFT_CONFIG or ~/.graft/config.json).")
    var config: String?

    @Option(name: .long, help: "Only check this pool (default: all pools).")
    var pool: String?

    @Flag(help: "Stop after minting a token — don't create/delete a probe runner.")
    var noProbe = false

    func run() async throws {
        let path = GraftConfig.resolvePath(explicit: config)
        let cfg = try GraftConfig.load(from: path)
        let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login
        let secrets = KeychainSecretStore(scope: scope)

        let pools = pool.map { name in cfg.pools.filter { $0.name == name } } ?? cfg.pools
        guard !pools.isEmpty else {
            throw GraftError(pool.map { "no pool named '\($0)'" } ?? "no pools in config")
        }

        func ok(_ message: String) { print("  ✓ \(message)") }
        func fail(_ step: String, _ error: Error) { printErr("  ✗ \(step): \(error)") }

        var failed = false
        for pool in pools {
            print("── pool '\(pool.name)'  (app \(pool.github.appId), \(pool.github.target)) ──")
            let client = GitHubAppClient(appID: pool.github.appId, secrets: secrets)

            let target: GitHubTarget
            do { target = try pool.github.parsedTarget() }
            catch { fail("parse target", error); failed = true; continue }

            do { _ = try await client.makeAppJWT(); ok("read key from \(scope.rawValue) keychain + signed App JWT") }
            catch { fail("sign App JWT", error); failed = true; continue }

            do {
                let id = try await client.installationID(for: target)
                ok("found App installation (#\(id))")
            } catch { fail("discover installation", error); failed = true; continue }

            do { _ = try await client.installationAccessToken(for: target); ok("minted installation access token") }
            catch { fail("mint installation token", error); failed = true; continue }

            if noProbe { continue }

            let probeName = "graft-doctor-" + UUID().uuidString.prefix(8).lowercased()
            do {
                let runner = try await client.generateJITRunner(pool: pool, runnerName: probeName)
                ok("generated JIT config (runner #\(runner.runnerID), \(runner.encodedConfig.count)-byte blob)")
                do {
                    try await client.deleteRunner(id: runner.runnerID, target: target)
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
