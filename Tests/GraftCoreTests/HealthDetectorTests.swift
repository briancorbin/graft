import Foundation
import Testing
@testable import GraftCore

@Suite("HealthDetector")
struct HealthDetectorTests {
    // MARK: auth

    @Test("AuthDetector reports a critical event per failing chain, none when healthy")
    func auth() async {
        struct Boom: Error {}
        let healthy = AuthDetector(probes: [
            .init(label: "org:ok") { .success(()) },
        ])
        #expect(await healthy.probe().isEmpty)

        let broken = AuthDetector(probes: [
            .init(label: "org:ok") { .success(()) },
            .init(label: "repo:acme/x") { .failure(Boom()) },
        ])
        let events = await broken.probe()
        #expect(events.count == 1)
        #expect(events.first?.severity == .critical)
        #expect(events.first?.category == .auth)
        #expect(events.first?.subject == "repo:acme/x")
    }

    // MARK: runner

    @Test("RunnerDetector flags only graft-named offline runners")
    func runner() async throws {
        let target = try GitHubTarget(parsing: "org:acme")
        let detector = RunnerDetector(
            scopes: [.init(label: "org:acme", target: target)],
            namePrefix: "graft-"
        ) { _ in
            [
                .init(id: 1, name: "graft-online", status: "online", busy: false),
                .init(id: 2, name: "graft-zombie", status: "offline", busy: false),
                .init(id: 3, name: "someone-elses-runner", status: "offline", busy: false),
            ]
        }
        let events = await detector.probe()
        #expect(events.count == 1)
        #expect(events.first?.subject == "graft-zombie")
        #expect(events.first?.category == .runner)
        #expect(events.first?.detail["runnerId"] == "2")
    }

    @Test("RunnerDetector skips runners the supervisor currently owns (no false husk)")
    func runnerOwnedExcluded() async throws {
        let target = try GitHubTarget(parsing: "org:acme")
        let detector = RunnerDetector(
            scopes: [.init(label: "org:acme", target: target)],
            namePrefix: "graft-",
            owned: { ["graft-live"] }            // the supervisor's live runner
        ) { _ in
            [
                .init(id: 1, name: "graft-live", status: "offline", busy: false),   // owned + briefly offline → skip
                .init(id: 2, name: "graft-husk", status: "offline", busy: false),   // not owned → genuine husk
            ]
        }
        let events = await detector.probe()
        #expect(events.count == 1)
        #expect(events.first?.subject == "graft-husk")
    }

    @Test("RunnerDetector stays quiet when listing fails (auth owns that)")
    func runnerListFailure() async throws {
        struct Boom: Error {}
        let target = try GitHubTarget(parsing: "org:acme")
        let detector = RunnerDetector(scopes: [.init(label: "org:acme", target: target)]) { _ in
            throw Boom()
        }
        #expect(await detector.probe().isEmpty)
    }

    // MARK: capacity

    @Test("CapacityDetector flags an OS shortfall and paused fleet workers")
    func capacity() async {
        let detector = CapacityDetector(
            desiredByOS: [.macOS: 2, .linux: 1],
            capacity: { os in os == .macOS ? 1 : 4 },   // macOS short by 1, linux fine
            fleet: { CapacityDetector.FleetSnapshot(totalSlots: 8, freeSlots: 0, pausedWorkers: ["worker-b"]) }
        )
        let events = await detector.probe()
        #expect(events.contains { $0.checkID == "capacity-shortfall" && $0.subject == "macos" })
        #expect(!events.contains { $0.checkID == "capacity-shortfall" && $0.subject == "linux" })
        #expect(events.contains { $0.checkID == "paused-worker" && $0.subject == "worker-b" })
    }

    @Test("CapacityDetector with no fleet and ample capacity is silent")
    func capacityHealthy() async {
        let detector = CapacityDetector(desiredByOS: [.macOS: 2], capacity: { _ in 2 })
        #expect(await detector.probe().isEmpty)
    }

    @Test("CapacityDetector: partial shortfall warns, zero capacity is critical")
    func capacitySeverity() async {
        let partial = CapacityDetector(desiredByOS: [.macOS: 2], capacity: { _ in 1 })
        #expect(await partial.probe().first?.severity == .warn)

        let outage = CapacityDetector(desiredByOS: [.macOS: 2], capacity: { _ in 0 })
        let events = await outage.probe()
        #expect(events.count == 1)
        #expect(events.first?.severity == .critical)
        #expect(events.first?.checkID == "capacity-shortfall")
    }

    @Test("ControllerReachabilityDetector fires critical only when the controller is down")
    func controllerReachability() async {
        let up = ControllerReachabilityDetector(controllerURL: "http://c:6120", reachable: { true })
        #expect(await up.probe().isEmpty)

        let down = ControllerReachabilityDetector(controllerURL: "http://c:6120", reachable: { false })
        let events = await down.probe()
        #expect(events.count == 1)
        #expect(events.first?.severity == .critical)
        #expect(events.first?.category == .capacity)
        #expect(events.first?.checkID == "controller-unreachable")
    }

    // MARK: leaf (wedged slot)

    @Test("SupervisorSlotDetector flags a transient slot past the timeout, ignores busy ones")
    func wedgedSlot() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let slots = [
            SlotStatus(tag: "mac#0", pool: "p", vmName: "graft-a", phaseLabel: "provisioning",
                       phaseKind: "provisioning", since: now.addingTimeInterval(-600)),  // 10 min
            SlotStatus(tag: "mac#1", pool: "p", vmName: "graft-b", phaseLabel: "running job: build",
                       phaseKind: "busy", since: now.addingTimeInterval(-3600)),         // long but busy
            SlotStatus(tag: "mac#2", pool: "p", vmName: "graft-c", phaseLabel: "acquiring",
                       phaseKind: "acquiring", since: now.addingTimeInterval(-30)),       // young
        ]
        let detector = SupervisorSlotDetector(
            slots: { slots },
            transientKinds: ["acquiring", "provisioning", "starting", "deregistering", "stopping"],
            stuckTimeout: 300,
            now: { now }
        )
        let events = await detector.probe()
        #expect(events.count == 1)
        #expect(events.first?.subject == "mac#0")
        #expect(events.first?.category == .leaf)
    }

    // MARK: supervisor (deadwood)

    @Test("DeadwoodDetector flags managed VMs no slot owns")
    func deadwood() async {
        let detector = DeadwoodDetector(
            managedVMNames: { ["graft-a", "graft-b", "graft-c"] },
            trackedVMNames: { ["graft-a"] }
        )
        let events = await detector.probe()
        #expect(Set(events.compactMap(\.subject)) == ["graft-b", "graft-c"])
        #expect(events.allSatisfy { $0.category == .supervisor && $0.checkID == "orphan-vm" })
    }

    @Test("DeadwoodDetector silent when everything is tracked")
    func deadwoodHealthy() async {
        let detector = DeadwoodDetector(
            managedVMNames: { ["graft-a"] },
            trackedVMNames: { ["graft-a", "graft-z"] }
        )
        #expect(await detector.probe().isEmpty)
    }
}
