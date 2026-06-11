import AppKit
import Combine
import Foundation
import GraftCore

/// Observable bridge between the menu-bar UI and the `graft` daemon. Reads live
/// status from the same files the CLI uses (state snapshot + pidfile) and drives
/// actions by shelling out to the `graft` binary — no IPC needed for v1.
@MainActor
final class GraftController: ObservableObject {
    @Published var isRunning = false
    @Published var runners: [RunnerRecord] = []
    @Published var activeProfile: String?
    @Published var profiles: [String] = []
    /// Transient note shown in the menu during an action (e.g. "Booting runners… 1/2").
    @Published var actionNote: String?
    /// True only while tearing down — blocks double-Stop (Start may still be
    /// interrupted by Stop).
    @Published var isStopping = false
    /// graft-managed VMs still on the host while no daemon is running — left by a
    /// daemon that didn't shut down cleanly (e.g. SIGKILL).
    @Published var orphans: [String] = []

    private let state = StateManager()
    private var timer: Timer?

    /// Bumped on every user action. A poll loop captures the token at launch and
    /// bails the moment a newer action supersedes it — so a Stop and a Start can't
    /// fight over the spinner.
    private var actionToken = 0

    init() {
        refresh()
        refreshOrphans()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshOrphans()
            }
        }
    }

    /// Re-read daemon liveness, the runner snapshot, and profiles. Also self-heals a
    /// stuck "Stopping…" if the daemon is actually gone.
    func refresh() {
        isRunning = Daemon.isRunning
        // Only trust the snapshot while the daemon is up — a crashed daemon leaves
        // a stale file, and showing phantom runners under "Stopped" is misleading.
        runners = isRunning ? (state.load()?.runners ?? []) : []
        activeProfile = Profiles.activeName()
        profiles = Profiles.names()
        if isStopping && !isRunning {
            isStopping = false
            actionNote = nil
        }
    }

    // MARK: Actions

    func start() {
        guard let graft = Self.graftPath else { return }
        actionToken += 1
        let token = actionToken
        let target = currentTarget()
        actionNote = target > 0 ? "Booting runners… 0/\(target)" : "Starting…"
        let log = NSHomeDirectory() + "/.graft/graft.log"
        runShell("nohup '\(graft)' run --daemon >> '\(log)' 2>&1 &")
        pollFill(token: token, target: target, attemptsRemaining: 360)
    }

    func stop() {
        guard let graft = Self.graftPath else { return }
        actionToken += 1
        let token = actionToken
        let targetPID = Daemon.runningPID()
        isStopping = true
        actionNote = "Stopping…"
        runProcess(graft, ["stop"])
        pollStop(token: token, pid: targetPID, attemptsRemaining: 240) { [weak self] in
            self?.isStopping = false
            self?.actionNote = nil
            self?.refresh()
        }
    }

    /// Switch the active profile. If the daemon is running, restart it so the new
    /// profile's pools take effect (the supervisor reads the active profile only at
    /// startup).
    func useProfile(_ name: String) {
        guard let graft = Self.graftPath, name != activeProfile else { return }
        runProcessSync(graft, ["profile", "use", name])
        activeProfile = name

        if isRunning {
            actionToken += 1
            let token = actionToken
            let targetPID = Daemon.runningPID()
            isStopping = true
            actionNote = "Switching to \(name)…"
            runProcess(graft, ["stop"])
            pollStop(token: token, pid: targetPID, attemptsRemaining: 240) { [weak self] in
                self?.isStopping = false
                self?.start()
            }
        } else {
            scheduleRefresh()
        }
    }

    var graftInstalled: Bool { Self.graftPath != nil }

    /// While stopped, look for leftover graft VMs on the host (off the main thread).
    func refreshOrphans() {
        guard !isRunning, let graft = Self.graftPath else {
            if !orphans.isEmpty { orphans = [] }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let names = Self.capture(graft, ["vm", "list"])
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let name = String(line.split(separator: "\t").first ?? "")
                    return name.hasPrefix("graft-") ? name : nil
                }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRunning else { return }
                self.orphans = names
            }
        }
    }

    /// Stop + delete every orphan VM (via `graft vm delete`).
    func killOrphans() {
        guard let graft = Self.graftPath, !orphans.isEmpty else { return }
        let names = orphans
        actionNote = "Removing \(names.count) orphan VM\(names.count == 1 ? "" : "s")…"
        DispatchQueue.global(qos: .userInitiated).async {
            for name in names { _ = Self.capture(graft, ["vm", "delete", name]) }
            DispatchQueue.main.async { [weak self] in
                self?.actionNote = nil
                self?.refreshOrphans()
            }
        }
    }

    // MARK: Poll loops (token-guarded)

    /// Poll until the daemon is up and the runner count reaches `target`, updating
    /// the progress note. Clears on fill, timeout, or supersession.
    private func pollFill(token: Int, target: Int, attemptsRemaining: Int) {
        guard token == actionToken else { return }
        refresh()
        if target > 0 { actionNote = "Booting runners… \(runners.count)/\(target)" }
        let filled = isRunning && (target == 0 || runners.count >= target)
        if filled || attemptsRemaining <= 0 {
            actionNote = nil
            refresh()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollFill(token: token, target: target, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    /// Poll until the specific daemon `pid` we stopped is gone (not "any daemon" —
    /// a freshly started one mustn't keep this spinning), then run `done`.
    private func pollStop(token: Int, pid: Int32?, attemptsRemaining: Int, done: @escaping () -> Void) {
        guard token == actionToken else { return }
        refresh()
        let gone = pid == nil || !Self.pidAlive(pid!)
        if gone || attemptsRemaining <= 0 {
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollStop(token: token, pid: pid, attemptsRemaining: attemptsRemaining - 1, done: done)
        }
    }

    /// Runners that will actually start for the active profile, after capacity
    /// clamping — the same number the supervisor will launch.
    private func currentTarget() -> Int {
        guard let name = activeProfile, let config = try? Profiles.load(name) else { return 0 }
        return config.plannedRunnerCount { LocalTartProvider.hostCapacity(for: $0) }
    }

    // MARK: Process plumbing

    /// Locate the `graft` binary (Homebrew, /usr/local, or a dev symlink). A GUI
    /// app's PATH is minimal, so we probe known locations.
    static let graftPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/graft",
            "/usr/local/bin/graft",
            NSHomeDirectory() + "/.local/bin/graft",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private static func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = Self.augmentedEnvironment
        try? process.run()
    }

    /// Run and wait — for quick commands like `profile use` whose effect we read
    /// immediately afterward.
    private func runProcessSync(_ launchPath: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = Self.augmentedEnvironment
        try? process.run()
        process.waitUntilExit()
    }

    private func runShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = Self.augmentedEnvironment
        try? process.run()
    }

    private static var augmentedEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// Run a command and capture stdout. For short reads like `graft vm list`.
    /// Call off the main thread — it blocks until the process exits.
    private static func capture(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = augmentedEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
