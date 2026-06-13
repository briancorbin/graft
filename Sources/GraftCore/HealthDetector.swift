import Foundation

/// A single health probe. Stateless by contract: `probe()` returns the problems that
/// are true *right now* (severity `.warn`/`.critical`). It does NOT emit `.recovered`,
/// suppress duplicates, or remember anything — `HealthMonitor` owns that edge-triggering
/// by diffing successive ticks. This keeps a detector a pure function of the world, so
/// it's trivial to test with injected closures.
public protocol HealthDetector: Sendable {
    /// Stable name, for logging which detector ran (e.g. "auth", "runner").
    var name: String { get }
    func probe() async -> [HealthEvent]
}

// MARK: - auth (docs: "rot")

/// Verifies the GitHub App auth chain (JWT → installation → token) for each distinct
/// target. One probe per target exercises the whole chain — minting a token requires all
/// three steps to succeed. Inject the chain as a closure so tests don't hit the network.
public struct AuthDetector: HealthDetector {
    public struct Probe: Sendable {
        public let label: String
        public let run: @Sendable () async -> Result<Void, Error>
        public init(label: String, run: @escaping @Sendable () async -> Result<Void, Error>) {
            self.label = label
            self.run = run
        }
    }

    let probes: [Probe]
    public var name: String { "auth" }

    public init(probes: [Probe]) { self.probes = probes }

    public func probe() async -> [HealthEvent] {
        var events: [HealthEvent] = []
        for probe in probes {
            if case .failure(let error) = await probe.run() {
                events.append(HealthEvent(
                    severity: .critical, category: .auth, checkID: "auth-chain",
                    subject: probe.label,
                    message: "GitHub App auth chain failed for \(probe.label)",
                    detail: ["error": "\(error)"],
                    suggestedAction: "verify the App PEM in keychain and the installation on \(probe.label) — `graft arborist`"
                ))
            }
        }
        return events
    }
}

// MARK: - runner (docs: "blight")

/// Flags graft-named runners that are *registered but offline* on GitHub — almost always
/// a deregistration that didn't land (a leaked husk). Non-graft runners and online runners
/// are ignored. (Aging an offline runner past a grace window needs cross-tick memory; that
/// lives in `HealthMonitor`, not here.)
public struct RunnerDetector: HealthDetector {
    public struct Scope: Sendable {
        public let label: String
        public let target: GitHubTarget
        public init(label: String, target: GitHubTarget) { self.label = label; self.target = target }
    }

    let scopes: [Scope]
    let namePrefix: String
    /// Runner names the supervisor currently owns (its tracked VM names == runner names).
    /// A just-registered JIT runner is briefly `offline` on GitHub before it connects, so
    /// without this the monitor flags its *own* live runners as husks. `track()` records the
    /// VM before the runner is registered, so excluding this set is race-free. Empty off-trunk.
    let owned: @Sendable () -> Set<String>
    let list: @Sendable (GitHubTarget) async throws -> [GitHubAppClient.Runner]
    public var name: String { "runner" }

    public init(
        scopes: [Scope],
        namePrefix: String = LocalTartProvider.namePrefix,
        owned: @escaping @Sendable () -> Set<String> = { [] },
        list: @escaping @Sendable (GitHubTarget) async throws -> [GitHubAppClient.Runner]
    ) {
        self.scopes = scopes
        self.namePrefix = namePrefix
        self.owned = owned
        self.list = list
    }

    public func probe() async -> [HealthEvent] {
        let mine = owned()
        var events: [HealthEvent] = []
        for scope in scopes {
            // A failed listing is an auth/connectivity problem that AuthDetector owns —
            // don't double-report it here.
            guard let runners = try? await list(scope.target) else { continue }
            for runner in runners
            where runner.isOffline && runner.name.hasPrefix(namePrefix) && !mine.contains(runner.name) {
                events.append(HealthEvent(
                    severity: .warn, category: .runner, checkID: "offline-runner",
                    subject: runner.name,
                    message: "graft runner registered but offline on \(scope.label) — likely a missed deregistration",
                    detail: ["target": scope.label, "runnerId": String(runner.id), "status": runner.status],
                    suggestedAction: "deregister it (`graft runners prune`) so the slot can replace it"
                ))
            }
        }
        return events
    }
}

// MARK: - capacity (docs: "drought")

/// Two capacity signals: (1) the configured desired count for an OS exceeds what the host
/// can fit (a permanent shortfall — pools will be clamped), and (2) on a fleet backend,
/// workers that are paused (their slots are unavailable). Fleet info is optional (Tart has
/// none); inject it only for Orchard.
public struct CapacityDetector: HealthDetector {
    /// What a fleet backend (Orchard) reports about itself.
    public struct FleetSnapshot: Sendable {
        public let totalSlots: Int
        public let freeSlots: Int
        public let pausedWorkers: [String]
        public init(totalSlots: Int, freeSlots: Int, pausedWorkers: [String]) {
            self.totalSlots = totalSlots
            self.freeSlots = freeSlots
            self.pausedWorkers = pausedWorkers
        }
    }

    let desiredByOS: [GuestOS: Int]
    let capacity: @Sendable (GuestOS) async -> Int
    let fleet: (@Sendable () async -> FleetSnapshot?)?
    public var name: String { "capacity" }

    public init(
        desiredByOS: [GuestOS: Int],
        capacity: @escaping @Sendable (GuestOS) async -> Int,
        fleet: (@Sendable () async -> FleetSnapshot?)? = nil
    ) {
        self.desiredByOS = desiredByOS
        self.capacity = capacity
        self.fleet = fleet
    }

    public func probe() async -> [HealthEvent] {
        var events: [HealthEvent] = []
        for (os, desired) in desiredByOS where desired > 0 {
            let cap = await capacity(os)
            if cap < desired {
                events.append(HealthEvent(
                    severity: .warn, category: .capacity, checkID: "capacity-shortfall",
                    subject: os.rawValue,
                    message: "want \(desired) \(os.rawValue) runner(s) but capacity is \(cap) — \(desired - cap) will stay unfilled",
                    detail: ["os": os.rawValue, "desired": String(desired), "capacity": String(cap)],
                    suggestedAction: "lower the pool count, add hosts/workers, or raise the backend ceiling"
                ))
            }
        }
        if let fleet, let snapshot = await fleet() {
            for worker in snapshot.pausedWorkers {
                events.append(HealthEvent(
                    severity: .warn, category: .capacity, checkID: "paused-worker",
                    subject: worker,
                    message: "fleet worker \(worker) is paused — its slots are unavailable",
                    detail: ["worker": worker, "freeSlots": String(snapshot.freeSlots), "totalSlots": String(snapshot.totalSlots)],
                    suggestedAction: "resume the worker if the pause was unintentional"
                ))
            }
        }
        return events
    }
}

/// Flags an **unreachable Orchard controller** — the scariest fleet failure to be silent
/// about: with the controller down, graft can place no leaves at all, yet `capacity()`
/// would just fall back to the static ceiling and say nothing. Orchard-only; injected
/// `reachable` keeps it off the network in tests.
public struct ControllerReachabilityDetector: HealthDetector {
    let controllerURL: String
    let reachable: @Sendable () async -> Bool
    public var name: String { "capacity" }

    public init(controllerURL: String, reachable: @escaping @Sendable () async -> Bool) {
        self.controllerURL = controllerURL
        self.reachable = reachable
    }

    public func probe() async -> [HealthEvent] {
        if await reachable() { return [] }
        return [HealthEvent(
            severity: .critical, category: .capacity, checkID: "controller-unreachable",
            subject: controllerURL,
            message: "Orchard controller \(controllerURL) is unreachable — no leaves can be placed",
            detail: ["controller": controllerURL],
            suggestedAction: "check the controller process + network; runner acquisition is blocked until it's back")]
    }
}

// MARK: - leaf (docs: "wilt")

/// Flags runner slots wedged in a *transient* phase past a timeout — a leaf that booted
/// but never became usable (the classic "stuck on provisioning" wedge). Long-running
/// phases like a busy slot mid-job are excluded via `transientKinds`.
public struct SupervisorSlotDetector: HealthDetector {
    let slots: @Sendable () -> [SlotStatus]
    let transientKinds: Set<String>
    let stuckTimeout: TimeInterval
    let now: @Sendable () -> Date
    public var name: String { "leaf" }

    public init(
        slots: @escaping @Sendable () -> [SlotStatus],
        transientKinds: Set<String>,
        stuckTimeout: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.slots = slots
        self.transientKinds = transientKinds
        self.stuckTimeout = stuckTimeout
        self.now = now
    }

    public func probe() async -> [HealthEvent] {
        let current = now()
        var events: [HealthEvent] = []
        for slot in slots() where transientKinds.contains(slot.phaseKind) {
            let age = current.timeIntervalSince(slot.since)
            guard age > stuckTimeout else { continue }
            events.append(HealthEvent(
                severity: .warn, category: .leaf, checkID: "wedged-slot",
                subject: slot.tag,
                message: "slot \(slot.tag) stuck in '\(slot.phaseLabel)' for \(Int(age))s (pool \(slot.pool))",
                detail: ["phase": slot.phaseKind, "ageSeconds": String(Int(age)),
                         "pool": slot.pool, "vm": slot.vmName ?? "-"],
                suggestedAction: "the leaf likely failed to come up — it should be reaped + replaced"
            ))
        }
        return events
    }
}

// MARK: - supervisor (docs: "deadwood")

/// Flags graft-managed VMs the backend still has that no supervised slot owns — leaked
/// "deadwood" from a crash or teardown race. Orphans are `managed − tracked`.
public struct DeadwoodDetector: HealthDetector {
    let managedVMNames: @Sendable () async -> [String]
    let trackedVMNames: @Sendable () -> Set<String>
    public var name: String { "supervisor" }

    public init(
        managedVMNames: @escaping @Sendable () async -> [String],
        trackedVMNames: @escaping @Sendable () -> Set<String>
    ) {
        self.managedVMNames = managedVMNames
        self.trackedVMNames = trackedVMNames
    }

    public func probe() async -> [HealthEvent] {
        let tracked = trackedVMNames()
        let orphans = await managedVMNames().filter { !tracked.contains($0) }
        return orphans.map { vm in
            HealthEvent(
                severity: .warn, category: .supervisor, checkID: "orphan-vm",
                subject: vm,
                message: "graft VM \(vm) is running but no slot owns it — leaked deadwood",
                detail: ["vm": vm],
                suggestedAction: "sweep it (`graft leaf rm \(vm)`) to reclaim its capacity"
            )
        }
    }
}
