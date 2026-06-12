import ArgumentParser
import Dispatch
import Foundation
import GraftCore

/// `graft run` — start the pool supervisor and keep pools filled until stopped.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the pool supervisor (runs until stopped)."
    )

    @Option(name: .shortAndLong, help: "Config path (overrides profile resolution).")
    var config: String?

    @Option(name: .long, help: "Profile to run (default: active profile).")
    var profile: String?

    @Flag(help: "Daemon mode for launchd. launchd does the supervising — this just notes intent.")
    var daemon = false

    @Flag(name: .shortAndLong, help: "Echo every step (runner output + events) above the live status, instead of just the spinner.")
    var verbose = false

    func run() async throws {
        let path = GraftConfig.resolvePath(explicit: config, profile: profile)
        let cfg = try GraftConfig.load(from: path)

        let problems = cfg.validate()
        guard problems.isEmpty else {
            for problem in problems { printErr("  • \(problem)") }
            throw GraftError("config has \(problems.count) problem(s) — run `graft config validate`")
        }

        let provider = try Self.makeProvider(cfg)
        let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login

        // Local Tart: pull any pool images that aren't cached yet (with progress) before
        // the live UI starts, so the first runner doesn't silently hang on a big download.
        // Orchard workers pull images themselves (image-pull-policy), so skip it there.
        if cfg.provider == "tart" {
            for image in Set(cfg.pools.map(\.image)).sorted() {
                try await Tart.ensureAvailable(image)
            }
        }

        // Live spinner dashboard only when we own an interactive terminal; daemon /
        // piped output keeps the plain log stream.
        let dashboard = (!daemon && isatty(STDOUT_FILENO) != 0) ? LiveDashboard() : nil
        dashboard?.start()
        if let dashboard {
            // Quiet by default: only warnings/errors print above the spinner. With
            // --verbose, echo every event + runner-output line. Phase parsing runs
            // regardless, so the spinner is fully driven either way.
            let verbose = self.verbose
            Log.sink = { line, isWarn in
                if verbose || isWarn { dashboard.log(line, isWarn: isWarn) }
            }
        }
        defer { Log.sink = nil; dashboard?.stop() }

        let reporter: RunnerStatusReporter? = dashboard.map { (d: LiveDashboard) -> RunnerStatusReporter in
            { tag, vm, phase in d.update(slot: tag, vm: vm, phase: phase) }
        }
        let supervisor = PoolSupervisor(
            config: cfg,
            provider: provider,
            secrets: KeychainSecretStore(scope: scope),
            status: reporter
        )

        try Daemon.writePidfile()
        defer { Daemon.removePidfile() }

        Log.info("graft starting — \(cfg.pools.count) pool(s), \(scope.rawValue) keychain\(daemon ? ", daemon" : "")")
        let task = Task { await supervisor.run() }
        let sources = installSignalHandlers {
            Log.info("signal received — shutting down gracefully")
            task.cancel()
        }
        defer { sources.forEach { $0.cancel() } }
        await task.value
    }

    /// Pick the VM backend from config: local Tart (single host) or an Orchard
    /// controller (multi-host fleet). `validate()` has already checked that an
    /// `orchard` block is present when the provider is "orchard".
    static func makeProvider(_ cfg: GraftConfig) throws -> any VMProvider {
        switch cfg.provider {
        case "tart":
            return LocalTartProvider()
        case "orchard":
            guard var orchard = cfg.orchard else {
                throw GraftError("provider is 'orchard' but no 'orchard' config block provided")
            }
            // Token resolution: explicit config value wins; otherwise pull it from the
            // Keychain (where `graft init` stashes it) so it's not in plaintext.
            // Left empty for an unsecured local `orchard dev`, which ignores auth.
            if (orchard.token ?? "").isEmpty {
                let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login
                orchard.token = KeychainSecretStore(scope: scope).orchardToken(account: orchard.serviceAccount)
            }
            return OrchardProvider(config: orchard)
        default:
            throw GraftError("unknown provider '\(cfg.provider)' — expected 'tart' or 'orchard'")
        }
    }
}

/// `graft status` — daemon liveness + the current runner snapshot.
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show supervisor and runner state."
    )

    func run() throws {
        if let pid = Daemon.runningPID() {
            print("daemon:  running (pid \(pid))")
        } else {
            print("daemon:  not running")
        }

        let runners = StateManager().load()?.runners ?? []
        guard !runners.isEmpty else {
            print("runners: none")
            return
        }
        print("runners: \(runners.count)")
        for record in runners.sorted(by: { $0.pool < $1.pool }) {
            print("  \(record.pool)\t\(record.vm.name)\t\(record.vm.ip)\t\(record.vm.os.rawValue)\tup \(age(record.startedAt))")
        }
    }
}

/// `graft stop` — signal a running supervisor to shut down gracefully.
struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Gracefully stop a running supervisor."
    )

    func run() throws {
        guard let pid = Daemon.runningPID() else {
            printErr("graft is not running")
            return
        }
        guard kill(pid, SIGTERM) == 0 else {
            throw GraftError("failed to signal pid \(pid)")
        }
        printErr("sent SIGTERM to graft (pid \(pid))")
    }
}

// MARK: - Runtime helpers

private func age(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
}

/// Trap SIGINT/SIGTERM and invoke `handler`. Returns the sources to keep alive.
private func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}
