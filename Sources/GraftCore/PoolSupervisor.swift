import Foundation

/// Supplies a JIT runner config for a pool. `GitHubAppClient` is the production
/// conformer; tests inject a mock. Keeps the supervisor off the network.
public protocol JITConfigProvider: Sendable {
    func generateJITConfig(pool: PoolConfig, runnerName: String) async throws -> String
}

/// Runs the ephemeral runner in a VM and returns its exit code.
/// `RunnerProvisioner` is the production conformer.
public protocol RunnerRunner: Sendable {
    func runEphemeralRunner(on vm: RunningVM, jitConfig: String) async throws -> Int32
}

extension GitHubAppClient: JITConfigProvider {}
extension RunnerProvisioner: RunnerRunner {}

/// The desired-state loop. Keeps each pool filled to its runner count, respecting
/// the host's per-OS capacity (Apple's 2-macOS-VM limit, budgeted across pools).
/// Each slot runs the full ephemeral loop forever: acquire → JIT → run one job →
/// release → repeat. Runs until the task is cancelled (graceful shutdown).
public actor PoolSupervisor {
    private let config: GraftConfig
    private let provider: any VMProvider
    private let github: @Sendable (Int) -> any JITConfigProvider
    private let runner: any RunnerRunner
    private let state: StateManager
    private var runners: [String: RunnerRecord] = [:]
    /// VMs currently being torn down — so the shutdown watcher and a slot's own
    /// teardown can't both fire `tart stop`/`delete` on the same VM and wedge tart
    /// on its per-VM lock inside an un-cancellable `Shell.run`.
    private var releasing: Set<String> = []

    /// `github` is a factory keyed by App ID — different pools can use different
    /// GitHub Apps (personal vs. work), each with its own client.
    public init(
        config: GraftConfig,
        provider: any VMProvider,
        github: @escaping @Sendable (Int) -> any JITConfigProvider,
        runner: any RunnerRunner,
        state: StateManager = StateManager()
    ) {
        self.config = config
        self.provider = provider
        self.github = github
        self.runner = runner
        self.state = state
    }

    /// Convenience for the production path: GitHub App clients backed by `secrets`,
    /// runner via the provider's exec channel.
    public init(
        config: GraftConfig,
        provider: any VMProvider,
        secrets: any SecretStore,
        state: StateManager = StateManager()
    ) {
        self.init(
            config: config,
            provider: provider,
            github: { appID in GitHubAppClient(appID: appID, secrets: secrets) },
            runner: RunnerProvisioner(provider: provider),
            state: state
        )
    }

    public func run() async {
        await reconcile()

        await withTaskGroup(of: Void.self) { group in
            // Budget capacity per OS across ALL pools (two macOS pools can't each
            // grab 2 VMs on a 2-VM host). Shared planner keeps this identical to the
            // target the menu-bar app shows.
            var capacityByOS: [GuestOS: Int] = [:]
            for os in GuestOS.allCases { capacityByOS[os] = await provider.capacity(for: os) }

            for (pool, slots) in config.plannedSlots(capacity: { capacityByOS[$0] ?? 0 }) {
                if slots < pool.count {
                    Log.warn("pool '\(pool.name)': clamped \(pool.count) → \(slots) (host \(pool.os.rawValue) capacity)")
                }
                Log.info("pool '\(pool.name)': \(slots) runner slot(s)")
                for slot in 0..<slots {
                    group.addTask { await self.runSlot(pool: pool, index: slot) }
                }
            }

            // Shutdown watcher: once cancelled, stop every tracked VM. Stopping a VM
            // kills its guest runner, which makes a slot's blocked `tart exec` return
            // so the slot can tear down and the group can complete. Without this, a
            // runner that ignores SIGTERM hangs the entire shutdown.
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                await self.stopTrackedVMs()
            }

            await group.waitForAll()
        }

        await cleanup()
    }

    // MARK: One runner slot

    private func runSlot(pool: PoolConfig, index: Int) async {
        let github = github(pool.github.appId)
        let tag = "\(pool.name)#\(index)"

        while !Task.isCancelled {
            do {
                let vm = try await provider.acquire(image: pool.image, os: pool.os)
                track(vm, pool: pool.name)
                Log.info("[\(tag)] acquired \(vm.name) (\(vm.ip))")

                do {
                    let jitConfig = try await github.generateJITConfig(pool: pool, runnerName: vm.name)
                    let exitCode = try await runner.runEphemeralRunner(on: vm, jitConfig: jitConfig)
                    Log.info("[\(tag)] runner \(vm.name) finished (exit \(exitCode))")
                } catch {
                    Log.warn("[\(tag)] runner \(vm.name) failed: \(error)")
                }

                await releaseOnce(vm)
            } catch {
                if Task.isCancelled { break }
                Log.warn("[\(tag)] acquire failed: \(error) — retrying in 5s")
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Tracking + persistence

    private func track(_ vm: RunningVM, pool: String) {
        runners[vm.name] = RunnerRecord(vm: vm, pool: pool, startedAt: Date())
        persist()
    }

    private func untrack(_ name: String) {
        runners[name] = nil
        persist()
    }

    /// Release a VM exactly once. The `releasing` check-and-insert runs
    /// synchronously on the actor (no `await` between), so the second caller — a
    /// slot's own teardown vs. the shutdown watcher — bails before issuing a
    /// duplicate `tart stop`/`delete` that would collide on tart's per-VM lock.
    private func releaseOnce(_ vm: RunningVM) async {
        guard releasing.insert(vm.name).inserted else { return }
        untrack(vm.name)
        try? await provider.release(vm)
        releasing.remove(vm.name)
    }

    private func persist() {
        do {
            try state.save(PoolState(runners: Array(runners.values), updatedAt: Date()))
        } catch {
            Log.warn("state save failed: \(error)")
        }
    }

    // MARK: Lifecycle

    /// Destroy leftovers from a prior run. With `tart exec`, the watching process
    /// died with us, so any surviving graft VM is a dead-runner husk — clean slate,
    /// then fill fresh. (Reattach isn't meaningful without a live exec channel.)
    private func reconcile() async {
        for record in state.load()?.runners ?? [] {
            Log.info("reconcile: releasing leftover \(record.vm.name)")
            try? await provider.release(record.vm)
        }
        // Sweep any graft-* VMs that never made it into state (crash before persist).
        await sweepGraftVMs()
        runners.removeAll()
        persist()
    }

    /// Stop every tracked VM — the reliable lever for breaking a slot blocked in
    /// `tart exec` during shutdown.
    private func stopTrackedVMs() async {
        for record in Array(runners.values) {
            Log.info("shutdown: stopping \(record.vm.name)")
            await releaseOnce(record.vm)
        }
    }

    /// Destroy any graft-managed VMs still on the host — belt-and-suspenders so a
    /// crash or a teardown race never leaves a VM (and its quota slot) behind.
    private func sweepGraftVMs() async {
        guard let tart = provider as? LocalTartProvider else { return }
        for vm in (try? await tart.graftManagedVMs()) ?? [] {
            Log.info("sweeping \(vm.name)")
            try? await Tart.stop(name: vm.name)
            try? await Tart.delete(name: vm.name)
        }
    }

    private func cleanup() async {
        for record in Array(runners.values) {
            Log.info("shutdown: releasing \(record.vm.name)")
            await releaseOnce(record.vm)
        }
        runners.removeAll()
        // Final sweep catches anything a slot's own teardown raced past.
        await sweepGraftVMs()
        persist()
        Log.info("graft stopped")
    }
}
