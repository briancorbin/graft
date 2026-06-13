import ArgumentParser
import Dispatch
import Foundation
import GraftCore

/// `graft arborist` — the tree-doctor: verify the whole GitHub App auth chain against
/// the real API without booting a VM: read key → sign JWT → find installation → mint
/// token → create a probe JIT runner → delete it. Leaves no trace on the org.
///
/// Run it bare and it picks the App from the keys in your keychain and prompts for
/// the target; or pass `--app-id`/`--target` to skip the prompts; or `--config`/
/// `--pool` to check pools from a config file.
struct Arborist: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arborist",
        abstract: "Tree-doctor: verify the GitHub App auth chain end-to-end (no VM boot)."
    )

    @Option(name: .long, help: "GitHub App ID for a one-off check (default: check the active profile's pools).")
    var appId: Int?

    @Option(name: .long, help: "Target 'org:NAME'/'repo:OWNER/NAME' for a one-off check (default: the active profile's pools).")
    var target: String?

    @Option(name: .long, help: "Runner group id for the probe runner (default 1).")
    var runnerGroupId: Int = 1

    @Option(name: .shortAndLong, help: "Check pools from this config file instead of the keychain.")
    var config: String?

    @Option(name: .long, help: "Check pools from this profile instead of the keychain.")
    var profile: String?

    @Option(name: .long, help: "With --config/--profile, only check this pool.")
    var pool: String?

    @Flag(help: "Use the system keychain instead of login.")
    var system = false

    @Flag(help: "Stop after minting a token — don't create/delete a probe runner.")
    var noProbe = false

    @Flag(help: "Tend continuously: run the full health-monitor loop (detection-only) until stopped.")
    var tend = false

    @Option(name: .long, help: "With --tend, seconds between sweeps (default: config `monitor.intervalSeconds`, else 60).")
    var interval: Int?

    func run() async throws {
        if tend { try await runTend(); return }

        let targets: [GitHubConfig]
        let scope: KeychainScope

        if appId != nil || target != nil {
            // Ad-hoc mode: an explicit App/target was given — check that one (prompt for
            // whichever half is missing). For one-off checks outside a profile.
            scope = system ? .system : .login
            let resolvedAppID = try appId ?? Self.pickAppID(scope: scope)
            let resolvedTarget = try target ?? Self.promptTarget()
            targets = [GitHubConfig(appId: resolvedAppID, target: resolvedTarget, runnerGroupId: runnerGroupId)]
        } else {
            // Profile mode (default): check the GitHub config every pool registers against
            // (resolved: pool override, else the profile default) — nothing to retype.
            let path = GraftConfig.resolvePath(explicit: config, profile: profile)
            let cfg = try GraftConfig.load(from: path)
            let filtered = pool.map { name in cfg.pools.filter { $0.name == name } } ?? cfg.pools
            guard !filtered.isEmpty else {
                throw GraftError(pool.map { "no pool named '\($0)'" }
                    ?? "no pools in the active profile — run `graft init`, or pass --app-id/--target for a one-off check")
            }
            var seen = Set<String>()
            targets = filtered.compactMap { cfg.gitHub(for: $0) }
                .filter { seen.insert("\($0.appId)|\($0.target)").inserted }
            guard !targets.isEmpty else {
                throw GraftError("profile has no GitHub config — set a top-level `github`, or pass --app-id/--target")
            }
            scope = system ? .system : (KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login)
        }

        let secrets = KeychainSecretStore(scope: scope)

        func ok(_ message: String) { print("  ✓ \(message)") }
        func fail(_ step: String, _ error: Error) { printErr("  ✗ \(step): \(error)") }

        var failed = false
        for gh in targets {
            print("── app \(gh.appId), \(gh.target) ──")
            let client = GitHubAppClient(appID: gh.appId, secrets: secrets)

            let parsedTarget: GitHubTarget
            do { parsedTarget = try gh.parsedTarget() }
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
                let runner = try await client.generateJITRunner(github: gh, labels: ["self-hosted"], runnerName: probeName)
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

    // MARK: Continuous tending (--tend)

    /// Run the detection-first health monitor against the active profile until stopped.
    /// Reuses the same auth/runner/capacity/slot/deadwood probes the one-shot doctor and
    /// supervisor already have — it just runs them on a cadence and reports. It does NOT
    /// remediate anything.
    private func runTend() async throws {
        let path = GraftConfig.resolvePath(explicit: config, profile: profile)
        let cfg = try GraftConfig.load(from: path)
        guard !cfg.pools.isEmpty else {
            throw GraftError("no pools in the active profile — run `graft init` first (or use the one-shot `graft arborist`)")
        }

        let scope = system ? .system : (KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login)
        let secrets = KeychainSecretStore(scope: scope)
        let provider = try Run.makeProvider(cfg)

        let intervalSeconds = interval ?? cfg.monitor?.intervalSeconds ?? 60
        let heartbeatConfig = cfg.monitor?.heartbeatSeconds ?? 300
        let heartbeat: TimeInterval? = heartbeatConfig > 0 ? TimeInterval(heartbeatConfig) : nil

        let detectors = HealthMonitorFactory.detectors(config: cfg, provider: provider, secrets: secrets)
        let reporter = HealthReporter(sinks: HealthMonitorFactory.sinks(monitor: cfg.monitor))
        let monitor = HealthMonitor(
            detectors: detectors, reporter: reporter,
            interval: .seconds(intervalSeconds), heartbeatSeconds: heartbeat
        )

        let webhookCount = cfg.monitor?.webhooks.count ?? 0
        printErr("arborist tending — \(detectors.count) detectors every \(intervalSeconds)s, "
            + "\(webhookCount) webhook(s); log → \(JSONLFileSink.defaultURL.path)")
        printErr("detection-only: nothing is remediated. Ctrl-C to stop.")

        let task = Task { await monitor.run() }
        let sources = Self.installSignalHandlers {
            printErr("\nstopping arborist…")
            task.cancel()
        }
        defer { sources.forEach { $0.cancel() } }
        await task.value
    }

    /// Trap SIGINT/SIGTERM and invoke `handler`. Returns the sources to keep alive.
    private static func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }

    // MARK: Interactive pickers

    /// Choose an App ID from the keys stored in the keychain. Auto-selects when
    /// there's only one. Listing reads attributes only — no Keychain prompt here.
    private static func pickAppID(scope: KeychainScope) throws -> Int {
        let ids = try KeychainSecretStore(scope: scope).storedAppIDs()
        guard !ids.isEmpty else {
            throw GraftError("no App keys in the \(scope.rawValue) keychain — run `graft secrets import --app-id <ID> --pem <path>`")
        }
        if ids.count == 1 {
            printErr("using app \(ids[0]) (only key in the \(scope.rawValue) keychain)")
            return ids[0]
        }
        printErr("App keys in the \(scope.rawValue) keychain:")
        for (index, id) in ids.enumerated() { printErr("  [\(index + 1)] \(id)") }
        while true {
            FileHandle.standardError.write(Data("pick one [1-\(ids.count)]: ".utf8))
            guard let line = readLine() else { throw GraftError("no selection made") }
            if let choice = Int(line.trimmingCharacters(in: .whitespaces)), (1...ids.count).contains(choice) {
                return ids[choice - 1]
            }
            printErr("  not a valid choice")
        }
    }

    private static func promptTarget() throws -> String {
        FileHandle.standardError.write(Data("target (org:NAME or repo:OWNER/NAME): ".utf8))
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else {
            throw GraftError("no target given")
        }
        return line
    }
}
