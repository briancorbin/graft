import Foundation

/// A consumer of health events. Detection-first: a sink *reports*, it never remediates.
/// The generic JSONL + webhook sinks are the trunk; Slack / PagerDuty / Sentry are
/// formatters that hang off the same stream later.
public protocol EventSink: Sendable {
    func emit(_ event: HealthEvent) async
}

/// Fans one event out to every configured sink. The monitor talks only to this.
public actor HealthReporter {
    private let sinks: [EventSink]

    public init(sinks: [EventSink]) { self.sinks = sinks }

    public func emit(_ event: HealthEvent) async {
        for sink in sinks { await sink.emit(event) }
    }

    public func emit(_ events: [HealthEvent]) async {
        for event in events { await emit(event) }
    }
}

// MARK: - Sinks

/// Bridges health events to the existing human `Log` (today's stdout/stderr behavior,
/// and the live-dashboard sink). This is what keeps `graft arborist` output unchanged.
public struct LogBridgeSink: EventSink {
    public init() {}

    public func emit(_ event: HealthEvent) async {
        let subject = event.subject.map { " \($0)" } ?? ""
        let line = "[\(event.category.rawValue)/\(event.checkID)]\(subject): \(event.message)"
        switch event.severity {
        case .warn, .critical: Log.warn(line)
        case .info, .recovered: Log.info(line)
        }
    }
}

/// Appends one JSON object per line to `~/.graft/logs/health.jsonl`. This is the
/// durable, pull-friendly record — `tail -f` it, ship it to anything line-oriented.
public actor JSONLFileSink: EventSink {
    private let fileURL: URL

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".graft/logs/health.jsonl")
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
    }

    public func emit(_ event: HealthEvent) async {
        guard var data = try? HealthEvent.compactEncoder.encode(event) else { return }
        data.append(0x0A) // newline → one event, one line
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // File doesn't exist yet — first write creates it.
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// POSTs each event as JSON to one or more webhook URLs. The vendor-neutral foundation:
/// a Slack/PagerDuty/Sentry receiver is a 5-line endpoint that reformats this payload.
/// Never throws — a dead webhook degrades to a warning, it doesn't break the monitor.
public actor WebhookSink: EventSink {
    private let urls: [URL]
    private let minSeverity: HealthEvent.Severity
    private let session: URLSession

    public init(
        urls: [URL],
        minSeverity: HealthEvent.Severity = .info,
        session: URLSession = .shared
    ) {
        self.urls = urls
        self.minSeverity = minSeverity
        self.session = session
    }

    public func emit(_ event: HealthEvent) async {
        guard !urls.isEmpty else { return }
        // Always deliver recoveries so a cleared problem isn't silently swallowed.
        guard event.severity == .recovered || event.severity.rank >= minSeverity.rank else { return }
        guard let body = try? HealthEvent.compactEncoder.encode(event) else { return }

        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("graft-arborist", forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    Log.warn("health webhook \(url.host ?? url.absoluteString) → HTTP \(http.statusCode)")
                }
            } catch {
                Log.warn("health webhook \(url.host ?? url.absoluteString) failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Maintains the *current* set of active problems in `~/.graft/state/health.json` —
/// the pull surface the menu-bar app and the future orchard dashboard read. A `warn`/
/// `critical` upserts by `key`; a `recovered` clears it. Starts empty each monitor run
/// (the snapshot reflects what the live monitor currently sees, not history).
public actor SnapshotSink: EventSink {
    public struct Snapshot: Codable, Sendable {
        public var problems: [HealthEvent]
        public var updatedAt: Date

        public init(problems: [HealthEvent] = [], updatedAt: Date = Date()) {
            self.problems = problems
            self.updatedAt = updatedAt
        }
    }

    private let fileURL: URL
    private var active: [String: HealthEvent] = [:]

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".graft/state/health.json")
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
    }

    public func emit(_ event: HealthEvent) async {
        switch event.severity {
        case .warn, .critical: active[event.key] = event
        case .recovered: active[event.key] = nil
        case .info: break // observations don't change the active-problem set
        }
        write()
    }

    /// The live view, sorted by key for deterministic output.
    public func current() -> Snapshot {
        Snapshot(problems: active.values.sorted { $0.key < $1.key }, updatedAt: Date())
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(current()) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
