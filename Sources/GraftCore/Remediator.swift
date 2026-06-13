import Foundation

/// The published seam for self-healing. **Not implemented yet** — graft is detection-only
/// today, by design: every signal is validated in the wild before anything is allowed to
/// act on it.
///
/// A future remediator is just another *consumer* of the `HealthEvent` stream the sinks
/// already carry — not a branch inside a detector. Detection stays a pure observation;
/// remediation is a deliberate, opt-in layer on top (reap a zombie runner, sweep deadwood,
/// refill a pool, restart a wedged slot), guarded by backoff + a circuit breaker so it
/// absorbs failures instead of amplifying them (naive healing hammering a dead backend is
/// worse than doing nothing).
///
/// A remediator reads `HealthEvent.suggestedAction` for the hint and dispatches on
/// `category` + `checkID`. It should run only behind an explicit opt-in
/// (e.g. a future `graft arborist --tend --heal`), never by default.
public protocol Remediator: Sendable {
    /// Decide and perform a remediation for one finding, returning what it did so the
    /// monitor can log/emit it. Today: unused — no conformers ship yet.
    func handle(_ event: HealthEvent) async -> RemediationOutcome
}

/// What a remediator did — or deliberately didn't do — about an event.
public enum RemediationOutcome: Sendable, Equatable {
    /// Not actionable, or below the configured policy.
    case ignored
    /// Actionable but withheld — backoff window, open circuit breaker, or dry-run.
    case skipped(reason: String)
    /// A remediation was performed; the string describes it (for the audit log).
    case acted(description: String)
}
