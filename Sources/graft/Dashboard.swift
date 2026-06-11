import Foundation
import GraftCore

/// A live, in-place terminal dashboard for interactive `graft run`: one spinner row
/// per runner slot showing what it's doing (booting VM → running → deregistering →
/// stopping), with `Log` lines scrolling above the live region.
///
/// Rendering is a single bottom-anchored block redrawn on a timer. Each redraw moves
/// the cursor to the top of the block and clears to end of screen (`ESC[<n>F` +
/// `ESC[0J`), prints any pending log lines (which become permanent scrollback), then
/// redraws the rows below — so the block always sits at the bottom and shrinks/grows
/// cleanly. TTY-only; the caller skips this entirely for daemon/piped output.
final class LiveDashboard: @unchecked Sendable {
    private struct Row { var vm: String?; var phase: RunnerPhase }

    private let lock = NSLock()
    private var order: [String] = []                 // slot tags, insertion order
    private var rows: [String: Row] = [:]
    private var pendingLogs: [String] = []
    private var prevLineCount = 0
    private var tick = 0
    private var running = false
    private var loop: Task<Void, Never>?

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let out = FileHandle.standardOutput

    // MARK: Lifecycle

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        Self.out.write(Data("\u{1B}[?25l".utf8))    // hide cursor
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.render()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    func stop() {
        loop?.cancel()
        lock.lock()
        running = false
        var output = eraseLiveRegion()
        output += flushPendingLogs()
        order.removeAll(); rows.removeAll(); prevLineCount = 0
        output += "\u{1B}[?25h"                      // show cursor
        Self.out.write(Data(output.utf8))
        lock.unlock()
    }

    // MARK: Feeds (called from supervisor tasks + the Log sink — all thread-safe)

    func update(slot: String, vm: String?, phase: RunnerPhase) {
        lock.lock(); defer { lock.unlock() }
        if phase == .done {
            rows[slot] = nil
            order.removeAll { $0 == slot }
        } else {
            if rows[slot] == nil { order.append(slot) }
            rows[slot] = Row(vm: vm ?? rows[slot]?.vm, phase: phase)
        }
    }

    func log(_ line: String, isWarn: Bool) {
        lock.lock(); defer { lock.unlock() }
        pendingLogs.append(line)
    }

    // MARK: Rendering

    private func render() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }

        var output = eraseLiveRegion()
        output += flushPendingLogs()

        let frame = Self.frames[tick % Self.frames.count]
        var lines = 0
        for tag in order {
            guard let row = rows[tag] else { continue }
            let label = tag.padding(toLength: 6, withPad: " ", startingAt: 0)
            let vm = Self.shortVM(row.vm)
            let gap = vm.isEmpty ? "" : "  \(vm)"
            output += "  \(frame) \(label)\(gap)  \(row.phase.label)\n"
            lines += 1
        }
        prevLineCount = lines
        tick += 1
        Self.out.write(Data(output.utf8))
    }

    /// Cursor to the top of the live block and clear everything below it.
    private func eraseLiveRegion() -> String {
        prevLineCount > 0 ? "\u{1B}[\(prevLineCount)F\u{1B}[0J" : ""
    }

    private func flushPendingLogs() -> String {
        guard !pendingLogs.isEmpty else { return "" }
        let text = pendingLogs.map { $0 + "\n" }.joined()
        pendingLogs.removeAll()
        return text
    }

    /// `graft-d62da19a-…` → `d62da19a` (the bit that distinguishes runners at a glance).
    private static func shortVM(_ vm: String?) -> String {
        guard let vm else { return "" }
        let stripped = vm.hasPrefix(LocalTartProvider.namePrefix) ? String(vm.dropFirst(LocalTartProvider.namePrefix.count)) : vm
        return String(stripped.prefix(8))
    }
}
