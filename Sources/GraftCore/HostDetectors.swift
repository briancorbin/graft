import Foundation

/// Host-level vitals for a worker (branch) or controller (trunk) Mac — the things only
/// the host itself can see, that the supervisor's API view can't (disk, memory, whether
/// `tart`/the controller is actually healthy). The "soil" the tree grows in.
public enum HostVitals {
    /// Free + total bytes on the volume containing `path` (default: home).
    public static func disk(path: String = NSHomeDirectory()) -> (free: Int64, total: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
              let total = (attrs[.systemSize] as? NSNumber)?.int64Value, total > 0
        else { return nil }
        return (free, total)
    }

    /// Names of stranded graft VMs in a `tart list` snapshot: `graft-`/`orchard-graft-`
    /// prefixed VMs that are **stopped**. A live runner VM is `running`; a stopped one is an
    /// ephemeral runner the worker never cleaned up (the controller has forgotten it, so
    /// graft's controller-side sweep can't reach it). Base images / OCI refs lack the prefix.
    public static func strandedGraftVMs(in vms: [TartVM]) -> [String] {
        vms.filter { ($0.name.hasPrefix("graft-") || $0.name.hasPrefix("orchard-graft-")) && !$0.isRunning }
           .map(\.name)
    }

    /// Free + total bytes of physical memory. "Free" counts free + inactive + speculative
    /// pages (inactive is reclaimable, so counting it avoids crying wolf on a healthy Mac
    /// that's just using RAM as cache). Mach `host_statistics64` — no subprocess.
    public static func memory() -> (free: Int64, total: Int64)? {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let freePages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.speculative_count)
        return (freePages * Int64(pageSize), total)
    }
}

private func gb(_ bytes: Int64) -> String { String(bytes / 1_000_000_000) }

// MARK: - host (docs: "soil")

/// Flags low free disk on the host. A full disk is the classic CI killer — leaves can't
/// boot, images can't pull. Thresholds are free-percent; inject `usage` for tests.
public struct DiskDetector: HealthDetector {
    let subject: String?
    let warnBelowPercent: Double
    let criticalBelowPercent: Double
    let usage: @Sendable () -> (free: Int64, total: Int64)?
    public var name: String { "host" }

    public init(
        subject: String?,
        warnBelowPercent: Double = 15,
        criticalBelowPercent: Double = 7,
        usage: @escaping @Sendable () -> (free: Int64, total: Int64)? = { HostVitals.disk() }
    ) {
        self.subject = subject
        self.warnBelowPercent = warnBelowPercent
        self.criticalBelowPercent = criticalBelowPercent
        self.usage = usage
    }

    public func probe() async -> [HealthEvent] {
        guard let (free, total) = usage(), total > 0 else { return [] }
        let freePercent = Double(free) / Double(total) * 100
        let severity: HealthEvent.Severity
        if freePercent <= criticalBelowPercent { severity = .critical }
        else if freePercent <= warnBelowPercent { severity = .warn }
        else { return [] }
        return [HealthEvent(
            severity: severity, category: .host, checkID: "disk-low", subject: subject,
            message: "disk \(Int(freePercent))% free (\(gb(free))/\(gb(total)) GB)",
            detail: ["freePercent": String(Int(freePercent)), "freeGB": gb(free), "totalGB": gb(total)],
            suggestedAction: "reclaim space — prune old Tart images / DerivedData; a full disk can't boot leaves")]
    }
}

/// Flags high memory use on the host. Thresholds are used-percent; inject `usage` for tests.
public struct MemoryDetector: HealthDetector {
    let subject: String?
    let warnAbovePercent: Double
    let criticalAbovePercent: Double
    let usage: @Sendable () -> (free: Int64, total: Int64)?
    public var name: String { "host" }

    public init(
        subject: String?,
        warnAbovePercent: Double = 85,
        criticalAbovePercent: Double = 95,
        usage: @escaping @Sendable () -> (free: Int64, total: Int64)? = { HostVitals.memory() }
    ) {
        self.subject = subject
        self.warnAbovePercent = warnAbovePercent
        self.criticalAbovePercent = criticalAbovePercent
        self.usage = usage
    }

    public func probe() async -> [HealthEvent] {
        guard let (free, total) = usage(), total > 0 else { return [] }
        let usedPercent = Double(total - free) / Double(total) * 100
        let severity: HealthEvent.Severity
        if usedPercent >= criticalAbovePercent { severity = .critical }
        else if usedPercent >= warnAbovePercent { severity = .warn }
        else { return [] }
        return [HealthEvent(
            severity: severity, category: .host, checkID: "memory-pressure", subject: subject,
            message: "memory \(Int(usedPercent))% used (\(gb(free)) GB free of \(gb(total)))",
            detail: ["usedPercent": String(Int(usedPercent)), "freeGB": gb(free), "totalGB": gb(total)],
            suggestedAction: "a leaf may OOM — reduce per-host VM count or `--reserve` more RAM on the branch")]
    }
}

/// A generic "is this thing responding?" probe — used for `tart` health on a branch and
/// controller-responsiveness on a trunk. Emits one critical event when the probe fails.
public struct CommandHealthDetector: HealthDetector {
    let checkID: String
    let subject: String?
    let message: String
    let action: String
    let isHealthy: @Sendable () async -> Bool
    public var name: String { "host" }

    public init(
        checkID: String, subject: String?, message: String, action: String,
        isHealthy: @escaping @Sendable () async -> Bool
    ) {
        self.checkID = checkID
        self.subject = subject
        self.message = message
        self.action = action
        self.isHealthy = isHealthy
    }

    public func probe() async -> [HealthEvent] {
        if await isHealthy() { return [] }
        return [HealthEvent(
            severity: .critical, category: .host, checkID: checkID, subject: subject,
            message: message, suggestedAction: action)]
    }
}

/// Flags **stranded tart VMs on a worker** — stopped `graft-`/`orchard-graft-` VMs the
/// controller no longer tracks, so graft's controller-side sweep can't reach them. Only the
/// worker can see these (it's the host running tart); left alone they leak disk. One event
/// per VM, keyed on the VM name so each clears independently as it's reclaimed. Inject
/// `leaked` for tests; the real wiring filters `Tart.list()` with `HostVitals.strandedGraftVMs`.
public struct WorkerOrphanDetector: HealthDetector {
    let worker: String
    let leaked: @Sendable () async -> [String]
    public var name: String { "host" }

    public init(worker: String, leaked: @escaping @Sendable () async -> [String]) {
        self.worker = worker
        self.leaked = leaked
    }

    public func probe() async -> [HealthEvent] {
        await leaked().map { vm in
            HealthEvent(
                severity: .warn, category: .host, checkID: "orphan-leaf", subject: vm,
                message: "stranded tart VM on \(worker) — stopped, the controller no longer tracks it (leaking disk)",
                detail: ["vm": vm, "worker": worker],
                suggestedAction: "reclaim it: `tart delete \(vm)`")
        }
    }
}
