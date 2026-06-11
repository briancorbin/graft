import Foundation

extension GraftConfig {
    /// Planned runner slots per pool after applying per-OS host capacity — the same
    /// budgeting the supervisor uses (macOS pools share the 2-VM ceiling host-wide,
    /// in config order). `capacity` returns the ceiling for an OS.
    public func plannedSlots(capacity: (GuestOS) -> Int) -> [(pool: PoolConfig, slots: Int)] {
        var budget: [GuestOS: Int] = [:]
        for os in GuestOS.allCases { budget[os] = capacity(os) }
        return pools.map { pool in
            let available = budget[pool.os] ?? 0
            let slots = max(0, min(pool.count, available))
            budget[pool.os] = available - slots
            return (pool, slots)
        }
    }

    /// Total runners that will actually start, after capacity clamping.
    public func plannedRunnerCount(capacity: (GuestOS) -> Int) -> Int {
        plannedSlots(capacity: capacity).reduce(0) { $0 + $1.slots }
    }
}
