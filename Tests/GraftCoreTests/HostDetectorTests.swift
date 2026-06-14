import Foundation
import Testing
@testable import GraftCore

@Suite("HostDetectors")
struct HostDetectorTests {
    @Test("DiskDetector escalates as free space drops")
    func disk() async {
        func sev(freePercent: Int) async -> HealthEvent.Severity? {
            let d = DiskDetector(subject: "mac-1", usage: { (Int64(freePercent), 100) })
            return await d.probe().first?.severity
        }
        #expect(await sev(freePercent: 50) == nil)        // healthy
        #expect(await sev(freePercent: 12) == .warn)      // ≤15
        #expect(await sev(freePercent: 5) == .critical)   // ≤7
    }

    @Test("MemoryDetector escalates as usage climbs")
    func memory() async {
        func sev(freePercent: Int) async -> HealthEvent.Severity? {
            let d = MemoryDetector(subject: "mac-1", usage: { (Int64(freePercent), 100) })
            return await d.probe().first?.severity
        }
        #expect(await sev(freePercent: 50) == nil)        // 50% used — healthy
        #expect(await sev(freePercent: 10) == .warn)      // 90% used ≥85
        #expect(await sev(freePercent: 2) == .critical)   // 98% used ≥95
    }

    @Test("Disk/Memory emit nothing when the host reading is unavailable")
    func noReading() async {
        #expect(await DiskDetector(subject: "x", usage: { nil }).probe().isEmpty)
        #expect(await MemoryDetector(subject: "x", usage: { nil }).probe().isEmpty)
    }

    @Test("CommandHealthDetector fires critical only when unhealthy")
    func commandHealth() async {
        let healthy = CommandHealthDetector(checkID: "tart-unhealthy", subject: "mac-1",
            message: "m", action: "a", isHealthy: { true })
        #expect(await healthy.probe().isEmpty)

        let sick = CommandHealthDetector(checkID: "tart-unhealthy", subject: "mac-1",
            message: "tart wedged", action: "a", isHealthy: { false })
        let events = await sick.probe()
        #expect(events.count == 1)
        #expect(events.first?.severity == .critical)
        #expect(events.first?.category == .host)
        #expect(events.first?.checkID == "tart-unhealthy")
    }

    @Test("HostVitals reads real disk + memory on this host")
    func realReadings() {
        let disk = HostVitals.disk()
        #expect(disk != nil)
        #expect((disk?.total ?? 0) > 0)
        #expect((disk?.free ?? -1) >= 0)

        let mem = HostVitals.memory()   // exercises the Mach host_statistics64 path for real
        #expect(mem != nil)
        #expect((mem?.total ?? 0) > 0)
        #expect((mem?.free ?? -1) >= 0)
    }

    @Test("strandedGraftVMs picks only stopped graft / orchard-graft VMs")
    func stranded() {
        let vms = [
            TartVM(name: "orchard-graft-live-0", state: "running", source: "local", size: nil),
            TartVM(name: "orchard-graft-dead-0", state: "stopped", source: "local", size: nil),
            TartVM(name: "graft-localdead", state: "stopped", source: "local", size: nil),
            TartVM(name: "g1-mobile-ci", state: "stopped", source: "local", size: nil),   // base image
            TartVM(name: "ghcr.io/cirruslabs/x", state: "stopped", source: "OCI", size: nil),
        ]
        #expect(Set(HostVitals.strandedGraftVMs(in: vms)) == ["orchard-graft-dead-0", "graft-localdead"])
    }

    @Test("WorkerOrphanDetector emits one event per stranded VM, quiet when none")
    func workerOrphan() async {
        #expect(await WorkerOrphanDetector(worker: "mac-1", leaked: { [] }).probe().isEmpty)

        let det = WorkerOrphanDetector(worker: "mac-1", leaked: { ["orchard-graft-aaa-0", "orchard-graft-bbb-0"] })
        let events = await det.probe()
        #expect(events.count == 2)
        #expect(Set(events.compactMap(\.subject)) == ["orchard-graft-aaa-0", "orchard-graft-bbb-0"])
        #expect(events.allSatisfy { $0.category == .host && $0.checkID == "orphan-leaf" })
    }

    @Test("branch + controller factories produce host detectors")
    func factories() {
        let branch = HealthMonitorFactory.branchDetectors(name: "mac-1")
        let trunk = HealthMonitorFactory.controllerDetectors(name: "ctrl", responding: { true })
        #expect(branch.count == 4)   // disk, memory, tart-health, worker-orphan
        #expect(trunk.count == 3)
        #expect(branch.allSatisfy { $0.name == "host" })
        #expect(trunk.allSatisfy { $0.name == "host" })
    }
}
