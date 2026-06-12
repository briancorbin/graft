import Foundation

/// `VMProvider` backed by the local `tart` CLI. Phase 1 backend — the supervisor
/// talks to this exactly the way it will later talk to Orchard.
public struct LocalTartProvider: VMProvider {
    /// Prefix for every VM graft creates, so `graft leaf list` and teardown can tell
    /// graft-managed VMs apart from anything else on the host.
    public static let namePrefix = "graft-"

    public init() {}

    /// Ceiling of VMs of this OS the host can run. macOS is Apple's kernel-enforced
    /// hard limit of 2; Linux is bounded by cores (heuristic, ~half). The supervisor
    /// enforces desired count against this — the provider just reports the ceiling.
    public func capacity(for os: GuestOS) async -> Int {
        Self.hostCapacity(for: os)
    }

    /// Synchronous host-capacity ceiling — Apple's hard 2-macOS-VM limit; Linux
    /// bounded by cores. Exposed so the UI can plan a target count without an async
    /// provider call.
    public static func hostCapacity(for os: GuestOS) -> Int {
        switch os {
        case .macOS:
            return 2
        case .linux:
            return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        }
    }

    public func acquire(image: String, os: GuestOS, mounts: [Mount] = [], network: VMNetwork = .nat) async throws -> RunningVM {
        let name = Self.namePrefix + UUID().uuidString.lowercased()
        try await Tart.clone(image: image, to: name)
        do {
            try Tart.run(name: name, mounts: mounts, network: network)
            let ip = try await Tart.waitForIP(name: name)
            return RunningVM(name: name, ip: ip, os: os)
        } catch {
            // Boot or IP wait failed — don't leak the clone.
            try? await Tart.stop(name: name)
            try? await Tart.delete(name: name)
            throw error
        }
    }

    public func release(_ vm: RunningVM) async throws {
        // Best-effort stop (a crashed VM may already be down), then delete.
        try? await Tart.stop(name: vm.name)
        guard try await Tart.exists(name: vm.name) else { return }
        try await Tart.delete(name: vm.name)
    }

    public func exec(on vm: RunningVM, _ command: [String], timeout: Duration? = nil) async throws -> ShellResult {
        try await Shell.run(Tart.executable, ["exec", vm.name] + command, timeout: timeout)
    }

    public func execStreaming(on vm: RunningVM, script: String, onLine: (@Sendable (String) -> Void)?) async throws -> Int32 {
        // `tart exec -i <name> bash -s` runs the script on stdin inside the guest;
        // stdout/stderr stream back, exit code propagates.
        try await Shell.runStreaming(
            Tart.executable,
            ["exec", "-i", vm.name, "bash", "-s"],
            stdin: script,
            onLine: onLine
        )
    }

    /// VMs graft created on this host (by name prefix). Backs `graft leaf list`.
    public func graftManagedVMs() async throws -> [TartVM] {
        try await Tart.list().filter { $0.name.hasPrefix(Self.namePrefix) }
    }

    /// Stop + delete any graft-managed VM still on this host (by name prefix).
    public func sweepOrphans() async {
        for vm in (try? await graftManagedVMs()) ?? [] {
            Log.info("sweeping \(vm.name)")
            try? await Tart.stop(name: vm.name)
            try? await Tart.delete(name: vm.name)
        }
    }
}
