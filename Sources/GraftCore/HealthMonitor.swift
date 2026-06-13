import Foundation

/// The continuous tending loop. Runs every detector on a cadence, **edge-triggers** the
/// results (emit a problem only when it's new or its severity changed; emit `.recovered`
/// when it clears), and beats a heartbeat so a silent monitor is distinguishable from a
/// dead one. Detection-first: it routes findings to sinks and never acts on them.
public actor HealthMonitor {
    private let detectors: [any HealthDetector]
    private let reporter: HealthReporter
    private let interval: Duration
    private let heartbeatSeconds: TimeInterval?   // nil disables
    private let now: @Sendable () -> Date

    /// Problems active as of the last tick, by `key` — the diff baseline.
    private var lastProblems: [String: HealthEvent] = [:]
    private var lastHeartbeat: Date?

    public init(
        detectors: [any HealthDetector],
        reporter: HealthReporter,
        interval: Duration = .seconds(60),
        heartbeatSeconds: TimeInterval? = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.detectors = detectors
        self.reporter = reporter
        self.interval = interval
        self.heartbeatSeconds = heartbeatSeconds
        self.now = now
    }

    /// Sweep once: gather problems, diff against the last sweep, emit changes +
    /// recoveries (+ a heartbeat when due). Public so callers/tests can step it.
    public func tick() async {
        // Dedup within a tick by key (distinct detectors shouldn't collide, but be safe).
        var current: [String: HealthEvent] = [:]
        for event in await gather() where current[event.key] == nil { current[event.key] = event }

        // New or severity-changed problems → emit. Unchanged → stay quiet.
        for (key, event) in current {
            if let previous = lastProblems[key], previous.severity == event.severity { continue }
            await reporter.emit(event)
        }
        // Problems that vanished this tick → recovered.
        for (key, previous) in lastProblems where current[key] == nil {
            await reporter.emit(previous.recovered(at: now()))
        }
        lastProblems = current

        await beatHeartbeatIfDue(activeProblems: current.count)
    }

    /// Run until the task is cancelled. Cancellation during the sleep ends the loop.
    public func run() async {
        while !Task.isCancelled {
            await tick()
            do { try await Task.sleep(for: interval) } catch { break }
        }
    }

    private func gather() async -> [HealthEvent] {
        await withTaskGroup(of: [HealthEvent].self) { group in
            for detector in detectors {
                group.addTask { await detector.probe() }
            }
            var all: [HealthEvent] = []
            for await events in group { all.append(contentsOf: events) }
            return all
        }
    }

    private func beatHeartbeatIfDue(activeProblems: Int) async {
        guard let heartbeatSeconds, heartbeatSeconds > 0 else { return }
        let due = lastHeartbeat.map { now().timeIntervalSince($0) >= heartbeatSeconds } ?? true
        guard due else { return }
        lastHeartbeat = now()
        await reporter.emit(HealthEvent(
            severity: .info, category: .supervisor, checkID: "heartbeat",
            message: "monitor alive — \(activeProblems) active problem(s)",
            detail: ["activeProblems": String(activeProblems)],
            timestamp: now()
        ))
    }
}

/// Assembles the standard detector set + sinks for a profile. Lives in GraftCore (not the
/// CLI) so the menu-bar app / a future daemon can build the same monitor. The detectors
/// re-use existing probes — the GitHub App auth chain, `listRunners`, `provider.capacity`,
/// the persisted slot phases, and `provider.managedVMNames()` — rather than paralleling them.
public enum HealthMonitorFactory {
    public static func detectors(
        config: GraftConfig,
        provider: any VMProvider,
        secrets: any SecretStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> [any HealthDetector] {
        // Distinct GitHub configs across the pools (same dedup as `graft arborist`).
        var seen = Set<String>()
        let githubs = config.pools.compactMap { config.gitHub(for: $0) }
            .filter { seen.insert("\($0.appId)|\($0.target)").inserted }

        var authProbes: [AuthDetector.Probe] = []
        var runnerScopes: [RunnerDetector.Scope] = []
        var clientsByTarget: [String: GitHubAppClient] = [:]
        for gh in githubs {
            guard let target = try? gh.parsedTarget() else { continue }
            let client = GitHubAppClient(appID: gh.appId, secrets: secrets)
            clientsByTarget[target.description] = client
            authProbes.append(.init(label: "\(gh.target) (app \(gh.appId))") {
                do { _ = try await client.installationAccessToken(for: target); return .success(()) }
                catch { return .failure(error) }
            })
            runnerScopes.append(.init(label: gh.target, target: target))
        }

        let clients = clientsByTarget
        let runnerList: @Sendable (GitHubTarget) async throws -> [GitHubAppClient.Runner] = { target in
            guard let client = clients[target.description] else { return [] }
            return try await client.listRunners(target: target)
        }

        var desiredByOS: [GuestOS: Int] = [:]
        for pool in config.pools { desiredByOS[pool.os, default: 0] += pool.count }
        let capacity: @Sendable (GuestOS) async -> Int = { os in await provider.capacity(for: os) }

        // Fleet info is Orchard-only — Tart has no workers to pause.
        let fleet: (@Sendable () async -> CapacityDetector.FleetSnapshot?)?
        if let orchard = provider as? OrchardProvider {
            fleet = {
                guard let report = try? await orchard.report() else { return nil }
                return CapacityDetector.FleetSnapshot(
                    totalSlots: report.totalSlots, freeSlots: report.freeSlots,
                    pausedWorkers: report.workers.filter(\.paused).map(\.name))
            }
        } else {
            fleet = nil
        }

        let state = StateManager()
        let transientPhases: Set<String> = [
            "acquiring", "provisioning", "starting", "connected", "deregistering", "stopping", "retrying",
        ]
        let stuckTimeout = TimeInterval(config.monitor?.slotStuckTimeoutSeconds ?? 300)

        return [
            AuthDetector(probes: authProbes),
            RunnerDetector(scopes: runnerScopes, list: runnerList),
            CapacityDetector(desiredByOS: desiredByOS, capacity: capacity, fleet: fleet),
            SupervisorSlotDetector(
                slots: { state.load()?.slots ?? [] },
                transientKinds: transientPhases, stuckTimeout: stuckTimeout, now: now),
            DeadwoodDetector(
                managedVMNames: { await provider.managedVMNames() },
                trackedVMNames: { Set((state.load()?.runners ?? []).map(\.vm.name)) }),
        ]
    }

    /// The standard sinks: human log + JSONL + snapshot, plus a webhook sink when the
    /// profile configures any. JSONL + snapshot are always on (cheap, local, the GUI
    /// reads them).
    public static func sinks(monitor: MonitorConfig?) -> [EventSink] {
        var sinks: [EventSink] = [LogBridgeSink(), JSONLFileSink(), SnapshotSink()]
        if let webhooks = monitor?.webhooks, !webhooks.isEmpty {
            sinks.append(WebhookSink(urls: webhooks, minSeverity: monitor?.resolvedWebhookMinSeverity ?? .warn))
        }
        return sinks
    }
}
