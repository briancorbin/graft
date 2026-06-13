import Foundation

/// Orchard controller env-var names (auth + endpoint), matching the `orchard` CLI.
public enum OrchardEnv {
    public static let url = "ORCHARD_URL"
    public static let accountName = "ORCHARD_SERVICE_ACCOUNT_NAME"
    public static let accountToken = "ORCHARD_SERVICE_ACCOUNT_TOKEN"
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
        self.token = config.token ?? ""   // nil → unset; resolved upstream or unused (dev)
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

    /// How many more VMs graft should ask for right now. We query the controller for
    /// the fleet's **live free `tart-vms` slots** (what each worker advertises minus
    /// what's already placed) and cap that at the configured `maxVMs` ceiling — so
    /// graft sizes its desired-state to real capacity instead of over-asking and
    /// churning create→pending→timeout→delete cycles (GFT-12). If the controller is
    /// unreachable we fall back to the static ceiling, so this is never worse than the
    /// old behavior.
    ///
    /// Orchard schedules macOS *and* Linux VMs from the **same** per-host `tart-vms`
    /// pool, so this returns the shared free-slot count for either `os`. For a
    /// single-OS fleet (the norm) the planner's per-OS budget is then exact; a mixed
    /// macOS+Linux fleet could still over-ask, but no worse than the static ceiling did.
    public func capacity(for os: GuestOS) async -> Int {
        guard let report = try? await report() else { return maxVMs }
        return min(report.freeSlots, maxVMs)
    }

    public func acquire(image: String, os: GuestOS, mounts: [Mount], network: VMNetwork, resources: VMResources, onProgress: (@Sendable (AcquireProgress) -> Void)?) async throws -> RunningVM {
        let name = Self.namePrefix + UUID().uuidString.lowercased()
        let args = Self.createArgs(name: name, image: image, os: os, mounts: mounts, network: network, resources: resources)

        let created = try await Shell.run(Self.executable, args, environment: env, timeout: .seconds(30))
        guard created.succeeded else {
            throw GraftError("`orchard create vm` failed: \(Self.message(created))")
        }
        onProgress?(.scheduling)   // submitted — the controller now has to place it on a branch
        do {
            let worker = try await waitForRunning(name, onProgress: onProgress)
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

    public func managedVMNames() async -> [String] {
        guard let listing = try? await rawList("vms") else { return [] }
        return Self.graftVMNames(in: listing)
    }

    /// Pull graft's own VM names out of `orchard list vms` table output — the name is the
    /// first whitespace-delimited column; the `Name` header and other rows are filtered out.
    static func graftVMNames(in listing: String) -> [String] {
        listing
            .split(whereSeparator: \.isNewline)
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
            .filter { $0.hasPrefix(namePrefix) }
    }

    // MARK: Fleet report — live capacity (GFT-12) + status surfaces (GFT-11)

    /// A worker as the controller sees it: its name, whether scheduling is paused, and
    /// the `tart-vms` slots it advertises (the per-host VM ceiling).
    public struct OrchardWorker: Sendable, Equatable {
        public let name: String
        public let paused: Bool
        public let slots: Int
        /// Seconds since this worker last heartbeated to the controller; nil if unknown.
        public let lastSeenAge: TimeInterval?
        public init(name: String, paused: Bool, slots: Int, lastSeenAge: TimeInterval? = nil) {
            self.name = name; self.paused = paused; self.slots = slots; self.lastSeenAge = lastSeenAge
        }

        /// A worker not seen within this window is a ghost — dead, but not yet reaped by the
        /// controller (which keeps counting its slots until heartbeat timeout). Excluding it
        /// keeps a killed worker from inflating capacity. Comfortably above any sane heartbeat
        /// interval, so a live worker is never false-flagged.
        public static let staleThreshold: TimeInterval = 120
        public var isStale: Bool { (lastSeenAge ?? 0) > Self.staleThreshold }
    }

    /// A live snapshot of the fleet: workers (with advertised slots), how many VMs are
    /// placed cluster-wide, and which of those are graft's. Backs both `capacity()` and
    /// the `graft tree status|branches` surfaces.
    public struct FleetReport: Sendable {
        public let controllerURL: String
        public let workers: [OrchardWorker]
        public let usedVMs: Int
        public let graftVMNames: [String]
        /// Slots advertised by workers that can actually take a VM right now — excludes
        /// paused workers *and* ghosts (stale heartbeat), so a dead worker the controller
        /// hasn't reaped doesn't inflate capacity.
        public var totalSlots: Int { workers.filter { !$0.paused && !$0.isStale }.reduce(0) { $0 + $1.slots } }
        /// Free `tart-vms` slots across the fleet: advertised minus every VM already
        /// placed (graft's and anyone else's — they all consume host slots).
        public var freeSlots: Int { max(0, totalSlots - usedVMs) }
    }

    /// Query the controller for a live fleet snapshot. One `get worker` call per worker
    /// — the CLI has no bulk resource view — but the callers (`capacity()` at planning
    /// time, `graft tree status`) are not hot loops, so the N+1 is fine. Throws if
    /// the controller is unreachable so `capacity` can fall back to the static ceiling.
    public func report() async throws -> FleetReport {
        let workersRaw = try await runOrchard(["list", "workers"])
        var workers: [OrchardWorker] = []
        for (name, paused) in Self.workerRows(in: workersRaw) {
            let slots = Self.tartVMSlots(inWorkerDetail: try await runOrchard(["get", "worker", name])) ?? 0
            // Absolute last-heartbeat via structpath (the table shows only a relative
            // "2 minutes ago"). A worker not seen recently is a ghost the controller hasn't
            // reaped — exclude its slots from capacity.
            let lastSeenRaw = try? await runOrchard(["get", "worker", "\(name)/lastSeen"])
            let age = lastSeenRaw.flatMap {
                Self.lastSeenAge(from: $0.trimmingCharacters(in: .whitespacesAndNewlines), now: Date())
            }
            workers.append(OrchardWorker(name: name, paused: paused, slots: slots, lastSeenAge: age))
        }
        let vmsRaw = try await runOrchard(["list", "vms"])
        return FleetReport(
            controllerURL: controllerURL, workers: workers,
            usedVMs: Self.vmCount(in: vmsRaw), graftVMNames: Self.graftVMNames(in: vmsRaw)
        )
    }

    /// Raw `orchard list <resource>` table output (e.g. for `graft tree leaves`), so the
    /// command surface can pass the controller's own formatting straight through.
    public func rawList(_ resource: String) async throws -> String {
        try await runOrchard(["list", resource])
    }

    /// Run an `orchard` subcommand and return stdout, throwing on a non-zero exit.
    /// Short timeout: capacity queries shouldn't stall startup on a slow controller.
    private func runOrchard(_ args: [String], timeout: Duration = .seconds(15)) async throws -> String {
        let result = try await Shell.run(Self.executable, args, environment: env, timeout: timeout)
        guard result.succeeded else {
            throw GraftError("`orchard \(args.joined(separator: " "))` failed: \(Self.message(result))")
        }
        return result.stdout
    }

    /// `(name, paused)` for every worker row in `orchard list workers` table output.
    /// Columns are space/tab-padded and "Last seen" has internal spaces, but the worker
    /// name is always the first token and the "Scheduling paused" bool the last — so we
    /// key off those two and skip the header + any malformed row.
    static func workerRows(in listing: String) -> [(name: String, paused: Bool)] {
        var rows: [(String, Bool)] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = tokens.first, let last = tokens.last, name != "Name" else { continue }
            switch last {
            case "false": rows.append((name, false))
            case "true": rows.append((name, true))
            default: continue   // skip non-row lines (header, blanks)
            }
        }
        return rows
    }

    /// Names of workers that can take new VMs (not scheduling-paused).
    static func schedulableWorkers(in listing: String) -> [String] {
        workerRows(in: listing).filter { !$0.paused }.map(\.name)
    }

    /// A worker's advertised `org.cirruslabs.tart-vms` count, parsed from the Resources
    /// block of `orchard get worker <name>` (the per-host VM ceiling Apple's 2-macOS
    /// limit is encoded as). nil if the field is absent.
    static func tartVMSlots(inWorkerDetail detail: String) -> Int? {
        for line in detail.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: "org.cirruslabs.tart-vms:") else { continue }
            let digits = line[r.upperBound...].drop { $0 == " " || $0 == "\t" }.prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    /// Age in seconds of an orchard worker `lastSeen` timestamp (Go's `time.String()`
    /// format, e.g. "2026-06-13 07:33:32.148021 -0700 PDT"). Robust by design: parses only
    /// the date + whole-second time + numeric offset, dropping the fractional seconds and
    /// the zone abbreviation (which `DateFormatter` handles poorly). nil if unparseable.
    static func lastSeenAge(from raw: String, now: Date) -> TimeInterval? {
        let tokens = raw.split(separator: " ")
        guard tokens.count >= 3 else { return nil }
        let day = String(tokens[0])
        let time = tokens[1].split(separator: ".").first.map(String.init) ?? String(tokens[1])
        let offset = String(tokens[2])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        guard let date = formatter.date(from: "\(day) \(time) \(offset)") else { return nil }
        return now.timeIntervalSince(date)
    }

    /// Count of VMs currently on the controller (all of them — every Tart VM consumes a
    /// host slot), from `orchard list vms` table output. Header row excluded.
    static func vmCount(in listing: String) -> Int {
        listing
            .split(whereSeparator: \.isNewline)
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
            .filter { $0 != "Name" }
            .count
    }

    // MARK: Argument building (pure — unit-tested)

    /// The full `orchard create vm …` argv for an ephemeral runner VM.
    static func createArgs(name: String, image: String, os: GuestOS, mounts: [Mount], network: VMNetwork, resources: VMResources = .none) -> [String] {
        // No --restart-policy: Orchard already defaults to "Never" (never auto-restart),
        // which is what ephemeral runners want. Passing it is fragile — the API only
        // accepts the capitalized "Never" and rejects the lowercase form.
        var args = [
            "create", "vm",
            "--image", image,
            "--os", orchardOS(os),
        ]
        if let cpu = resources.cpu { args += ["--cpu", String(cpu)] }
        if let memory = resources.memory {
            args += ["--memory", String(memory)]
            // Also request it as a schedulable resource so the controller only places
            // this leaf on a branch with that much memory free (no over-packing → OOM).
            args += ["--resources", "org.cirruslabs.memory-mib=\(memory)"]
        }
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
        pollInterval: Duration = .seconds(3),
        onProgress: (@Sendable (AcquireProgress) -> Void)? = nil
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            switch (try? await field(name, "status"))?.lowercased() ?? "" {
            case "running":
                onProgress?(.booting)   // a branch took it — the guest is now coming up
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
