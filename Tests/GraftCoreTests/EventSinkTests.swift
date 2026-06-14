import Foundation
import Testing
@testable import GraftCore

@Suite("EventSink")
struct EventSinkTests {
    /// Collects everything it's handed, for asserting fan-out.
    actor Recorder: EventSink {
        private(set) var events: [HealthEvent] = []
        func emit(_ event: HealthEvent) async { events.append(event) }
        func count() -> Int { events.count }
    }

    private func sampleEvent(_ checkID: String, severity: HealthEvent.Severity = .warn,
                             subject: String? = nil) -> HealthEvent {
        HealthEvent(severity: severity, category: .capacity, checkID: checkID,
                    subject: subject, message: "m")
    }

    @Test("HealthReporter fans one event out to every sink")
    func reporterFanOut() async {
        let a = Recorder(), b = Recorder()
        let reporter = HealthReporter(sinks: [a, b])
        await reporter.emit(sampleEvent("free-slots"))
        #expect(await a.count() == 1)
        #expect(await b.count() == 1)
    }

    @Test("JSONLFileSink appends one decodable line per event")
    func jsonlAppends() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-test-\(UUID().uuidString)")
            .appendingPathComponent("health.jsonl")
        let sink = JSONLFileSink(fileURL: tmp)
        await sink.emit(sampleEvent("a"))
        await sink.emit(sampleEvent("b"))
        await sink.emit(sampleEvent("c"))

        let contents = String(decoding: try Data(contentsOf: tmp), as: UTF8.self)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        for line in lines {
            let event = try HealthEvent.decoder.decode(
                HealthEvent.self, from: Data(line.utf8))
            #expect(event.category == .capacity)
        }
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    @Test("SnapshotSink upserts problems by key and clears them on recovery")
    func snapshotLifecycle() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-test-\(UUID().uuidString)")
            .appendingPathComponent("health.json")
        let sink = SnapshotSink(fileURL: tmp)

        await sink.emit(sampleEvent("free-slots", subject: "macOS"))
        await sink.emit(sampleEvent("paused-worker", subject: "worker-1"))
        #expect(await sink.current().problems.count == 2)

        // A second warn on the same key replaces, doesn't duplicate.
        await sink.emit(sampleEvent("free-slots", severity: .critical, subject: "macOS"))
        #expect(await sink.current().problems.count == 2)

        // Recovery clears just that one.
        await sink.emit(HealthEvent(severity: .recovered, category: .capacity,
                                    checkID: "free-slots", subject: "macOS", message: "ok"))
        let remaining = await sink.current().problems
        #expect(remaining.count == 1)
        #expect(remaining.first?.checkID == "paused-worker")

        // It was persisted to disk, too.
        let onDisk = try HealthEvent.decoder.decode(
            SnapshotSink.Snapshot.self, from: Data(contentsOf: tmp))
        #expect(onDisk.problems.count == 1)
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    @Test("info observations never enter the active-problem set")
    func infoIgnoredBySnapshot() async {
        let sink = SnapshotSink(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-test-\(UUID().uuidString)/health.json"))
        await sink.emit(sampleEvent("heartbeat", severity: .info))
        #expect(await sink.current().problems.isEmpty)
    }
}
