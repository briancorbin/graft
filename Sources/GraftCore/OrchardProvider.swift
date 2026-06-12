import Foundation

/// Orchard controller env-var names (auth + endpoint), matching the `orchard` CLI.
enum OrchardEnv {
    static let url = "ORCHARD_URL"
    static let accountName = "ORCHARD_SERVICE_ACCOUNT_NAME"
    static let accountToken = "ORCHARD_SERVICE_ACCOUNT_TOKEN"
}

/// `VMProvider` backed by the `orchard` CLI talking to an Orchard controller — the
/// multi-host fleet backend. The supervisor drives this identically to local Tart;
/// the difference is the controller schedules each VM onto one of a cluster of Apple
/// Silicon workers (and owns Apple's per-host 2-macOS-VM limit).
///
/// Every `orchard` invocation carries the controller URL + service-account creds in
/// its environment, so graft never runs `orchard context create` or touches the
/// user's `~/.config/orchard`. Exec rides Orchard's own websocket-tunneled SSH via
/// `orchard ssh vm`, so we don't need a VM IP — VMs are addressed by name cluster-wide.
public struct OrchardProvider: VMProvider {
    /// Prefix on every VM graft creates, so listing + the orphan sweep can tell graft's
    /// VMs apart from anything else on the cluster.
    public static let namePrefix = "graft-"
    static let executable = "orchard"

    let controllerURL: String
    let serviceAccount: String
    let token: String
    let maxVMs: Int

    public init(config: OrchardConfig) {
        self.controllerURL = config.controllerURL.absoluteString
        self.serviceAccount = config.serviceAccount
        self.token = config.token
        self.maxVMs = config.maxVMs ?? 100
    }

    /// Auth + endpoint injected into every `orchard` call (no `orchard context` needed).
    var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e[OrchardEnv.url] = controllerURL
        e[OrchardEnv.accountName] = serviceAccount
        e[OrchardEnv.accountToken] = token
        return e
    }

    // MARK: VMProvider

    /// The controller does the real scheduling (and owns Apple's per-host 2-macOS-VM
    /// limit), so graft doesn't second-guess it — we report the configured ceiling and
    /// let the controller queue anything that doesn't fit right now.
    public func capacity(for os: GuestOS) async -> Int { maxVMs }

    public func acquire(image: String, os: GuestOS, mounts: [Mount] = [], network: VMNetwork = .nat) async throws -> RunningVM {
        let name = Self.namePrefix + UUID().uuidString.lowercased()
        let args = Self.createArgs(name: name, image: image, os: os, mounts: mounts, network: network)

        let created = try await Shell.run(Self.executable, args, environment: env, timeout: .seconds(30))
        guard created.succeeded else {
            throw GraftError("`orchard create vm` failed: \(Self.message(created))")
        }
        do {
            let worker = try await waitForRunning(name)
            return RunningVM(name: name, ip: worker, os: os)
        } catch {
            // Don't leak a scheduled-but-doomed VM.
            try? await release(RunningVM(name: name, ip: "", os: os))
            throw error
        }
    }

    public func release(_ vm: RunningVM) async throws {
        // Idempotent: deleting an already-gone VM must not throw the slot's teardown.
        _ = try? await Shell.run(Self.executable, ["delete", "vm", vm.name], environment: env, timeout: .seconds(30))
    }

    public func exec(on vm: RunningVM, _ command: [String], timeout: Duration? = nil) async throws -> ShellResult {
        // `orchard ssh vm NAME "<cmd>"` runs over the controller's SSH tunnel.
        try await Shell.run(
            Self.executable,
            Self.sshArgs(vmName: vm.name, remoteCommand: command.joined(separator: " ")),
            environment: env,
            timeout: timeout
        )
    }

    public func execStreaming(on vm: RunningVM, script: String, onLine: (@Sendable (String) -> Void)?) async throws -> Int32 {
        // `bash -s` reads the script on stdin (forwarded through the SSH session). The
        // orchard CLI exits 0 iff the remote command exited 0 — graft only needs the
        // 0/non-zero distinction, which is preserved (exact non-zero codes are not).
        try await Shell.runStreaming(
            Self.executable,
            Self.sshArgs(vmName: vm.name, remoteCommand: "bash -s"),
            stdin: script,
            environment: env,
            onLine: onLine
        )
    }

    /// `orchard ssh vm <name> <remoteCommand>` argv.
    ///
    /// ⚠️ Do NOT pass `--wait 0`. Orchard's `--wait` is the deadline for the *entire
    /// port-forward rendezvous* (the controller waiting for the worker to pick up the
    /// request and stand up the SSH tunnel) — not merely "wait for the VM to be running".
    /// `--wait 0` gives that rendezvous a zero deadline, so it dies in ~100µs with
    /// "context deadline exceeded" before the worker can ever respond, and exec never
    /// works. Omitting `--wait` uses Orchard's 60s default, which is what we want.
    static func sshArgs(vmName: String, remoteCommand: String) -> [String] {
        ["ssh", "vm", vmName, remoteCommand]
    }

    /// Delete every graft-managed VM still registered on the controller (by name prefix).
    public func sweepOrphans() async {
        // Plain `list vms` (no `--quiet`: that flag doesn't exist in older Orchard
        // releases, e.g. 0.55.0 — using it makes the whole sweep silently no-op). Parse
        // the VM name out of the first column instead, which works on any version.
        guard let result = try? await Shell.run(
            Self.executable, ["list", "vms"], environment: env, timeout: .seconds(20)
        ), result.succeeded else { return }
        for name in Self.graftVMNames(in: result.stdout) {
            Log.info("sweeping \(name)")
            _ = try? await Shell.run(Self.executable, ["delete", "vm", name], environment: env, timeout: .seconds(30))
        }
    }

    /// Pull graft's own VM names out of `orchard list vms` table output — the name is the
    /// first whitespace-delimited column; the `Name` header and other rows are filtered out.
    static func graftVMNames(in listing: String) -> [String] {
        listing
            .split(whereSeparator: \.isNewline)
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
            .filter { $0.hasPrefix(namePrefix) }
    }

    // MARK: Argument building (pure — unit-tested)

    /// The full `orchard create vm …` argv for an ephemeral runner VM.
    static func createArgs(name: String, image: String, os: GuestOS, mounts: [Mount], network: VMNetwork) -> [String] {
        // No --restart-policy: Orchard already defaults to "Never" (never auto-restart),
        // which is what ephemeral runners want. Passing it is fragile — the API only
        // accepts the capitalized "Never" and rejects the lowercase form.
        var args = [
            "create", "vm",
            "--image", image,
            "--os", orchardOS(os),
        ]
        for mount in mounts { args += ["--host-dirs", mount.tartDirArg] }
        args += network.orchardFlags
        args.append(name)
        return args
    }

    /// Orchard's `--os` value. NB: scheduling a macOS image as `linux` is Orchard's
    /// documented escape hatch from Apple's 2-macOS-VM/host cap — but graft passes the
    /// pool's declared OS straight through; that trick is the operator's call in config.
    static func orchardOS(_ os: GuestOS) -> String {
        switch os {
        case .macOS: return "darwin"
        case .linux: return "linux"
        }
    }

    // MARK: Helpers

    /// Poll `orchard get vm <name>/status` until the controller+worker bring the VM to
    /// `running` (returning the assigned worker), or it goes `failed` / we time out.
    /// Generous deadline: a cold worker may pull the image before booting.
    private func waitForRunning(
        _ name: String,
        timeout: Duration = .seconds(600),
        pollInterval: Duration = .seconds(3)
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            switch (try? await field(name, "status"))?.lowercased() ?? "" {
            case "running":
                let worker = try? await field(name, "worker")
                return (worker?.isEmpty == false) ? worker! : "orchard"
            case "failed":
                let msg = (try? await field(name, "status_message")) ?? ""
                throw GraftError("orchard VM \(name) failed\(msg.isEmpty ? "" : ": \(msg)")")
            default:
                try await Task.sleep(for: pollInterval)
            }
        }
        throw GraftError("orchard VM \(name) wasn't running within \(timeout)")
    }

    /// One field of a VM via structpath — `orchard get vm <name>/<jsonKey>` prints the raw value.
    private func field(_ name: String, _ jsonKey: String) async throws -> String {
        let result = try await Shell.run(
            Self.executable, ["get", "vm", "\(name)/\(jsonKey)"], environment: env, timeout: .seconds(15)
        )
        guard result.succeeded else {
            throw GraftError("`orchard get vm \(name)/\(jsonKey)` failed: \(Self.message(result))")
        }
        return result.stdoutTrimmed
    }

    /// Prefer stderr for an error message, fall back to stdout.
    static func message(_ r: ShellResult) -> String {
        r.stderrTrimmed.isEmpty ? r.stdoutTrimmed : r.stderrTrimmed
    }
}
