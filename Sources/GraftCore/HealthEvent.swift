import Foundation

/// One health finding, emitted by a detector or a supervisor phase transition.
///
/// Detection-first: an event *describes* state, it never acts. `suggestedAction` is a
/// forward-looking hint for the (not-yet-built) remediation layer — nothing consumes it
/// today. A future `Remediator` subscribes to the same stream these sinks already carry.
public struct HealthEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Severity: String, Codable, Sendable, CaseIterable {
        case info        // a normal, non-problem observation (e.g. a heartbeat)
        case warn        // degraded, worth a look, not yet on fire
        case critical    // actively broken / will drop jobs
        case recovered   // a previously-emitted problem has cleared

        /// Ordering for sink severity floors. `recovered` ranks with `info`, but sinks
        /// generally deliver it regardless so recovery notices aren't swallowed.
        public var rank: Int {
            switch self {
            case .info, .recovered: return 0
            case .warn: return 1
            case .critical: return 2
            }
        }
    }

    /// Machine-facing category — deliberately plain so webhook / Sentry / PagerDuty
    /// consumers and the future GUI get stable strings. The horticultural labels
    /// (deadwood, blight, wilt, drought, rot) live in docs and human messages, not here.
    public enum Category: String, Codable, Sendable, CaseIterable {
        case auth         // GitHub App auth chain / token TTL        (docs: "rot")
        case runner       // registered-runner zombies / offline      (docs: "blight")
        case capacity     // host & fleet capacity / paused workers   (docs: "drought")
        case leaf         // VM liveness / wedged guests              (docs: "wilt")
        case supervisor   // slot stuck / orphans / desired-vs-actual (docs: "deadwood")
    }

    public let timestamp: Date
    public var severity: Severity
    public var category: Category
    /// Stable sub-identifier within a category, e.g. "token-ttl", "offline-runner",
    /// "free-slots", "wedged-guest", "orphan-vm", "slot-stuck". Combined with
    /// `category` + `subject` it forms `key`, which is what lets the monitor diff
    /// tick-over-tick and pair a problem with its `.recovered`.
    public var checkID: String
    /// What the event is about: a pool, vm, runner, or host name — nil if global.
    public var subject: String?
    public var message: String
    public var detail: [String: String]
    public var suggestedAction: String?

    public init(
        severity: Severity,
        category: Category,
        checkID: String,
        subject: String? = nil,
        message: String,
        detail: [String: String] = [:],
        suggestedAction: String? = nil,
        timestamp: Date = Date()
    ) {
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.checkID = checkID
        self.subject = subject
        self.message = message
        self.detail = detail
        self.suggestedAction = suggestedAction
    }

    /// Identity of the *condition*: same key ⇒ same problem on the same subject. The
    /// monitor edge-triggers on this (emit on change + heartbeat, not every tick) and
    /// uses it to clear a problem when its `.recovered` arrives.
    public var key: String { "\(category.rawValue):\(checkID):\(subject ?? "-")" }

    /// A distinct identity per emission (key + when), for `Identifiable` / dedup in UIs.
    public var id: String { "\(key)@\(timestamp.timeIntervalSince1970)" }

    public var isProblem: Bool { severity == .warn || severity == .critical }

    /// The `.recovered` counterpart of this problem, preserving `key` (category /
    /// checkID / subject) so a snapshot sink clears the matching active problem.
    public func recovered(at time: Date = Date()) -> HealthEvent {
        HealthEvent(
            severity: .recovered, category: category, checkID: checkID, subject: subject,
            message: "recovered: \(message)", detail: detail, suggestedAction: nil, timestamp: time
        )
    }

    /// Compact, single-line, stable-key encoding — for JSONL and webhook bodies.
    /// (No pretty-printing: one event must serialize to exactly one line.)
    public static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
