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
    /// Transient note shown in the menu during an action (e.g. "Switching profile…").
    @Published var actionNote: String?

    private let state = StateManager()
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-read daemon liveness, the runner snapshot, and profiles.
    func refresh() {
        isRunning = Daemon.isRunning
        runners = state.load()?.runners ?? []
        activeProfile = Profiles.activeName()
        profiles = Profiles.names()
    }

    // MARK: Actions

    func start() {
        guard let graft = Self.graftPath else { return }
        actionNote = "Starting…"
        let log = NSHomeDirectory() + "/.graft/graft.log"
        runShell("nohup '\(graft)' run --daemon >> '\(log)' 2>&1 &")
        scheduleRefresh()
    }

    func stop() {
        guard let graft = Self.graftPath else { return }
        actionNote = "Stopping…"
        runProcess(graft, ["stop"])
        scheduleRefresh()
    }

    /// Switch the active profile. If the daemon is running, restart it so the new
    /// profile's pools actually take effect (the supervisor reads the active profile
    /// only at startup).
    func useProfile(_ name: String) {
        guard let graft = Self.graftPath, name != activeProfile else { return }
        runProcessSync(graft, ["profile", "use", name])
        activeProfile = name

        if isRunning {
            actionNote = "Switching to \(name)…"
            runProcess(graft, ["stop"])
            waitForStop(attemptsRemaining: 120) { [weak self] in
                self?.start()
            }
        } else {
            scheduleRefresh()
        }
    }

    var graftInstalled: Bool { Self.graftPath != nil }

    /// Poll until the daemon's pidfile clears (graceful teardown can take a few
    /// seconds per VM), then run `then`. Refreshes the UI while waiting.
    private func waitForStop(attemptsRemaining: Int, then: @escaping () -> Void) {
        refresh()
        if attemptsRemaining <= 0 || !Daemon.isRunning {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForStop(attemptsRemaining: attemptsRemaining - 1, then: then)
        }
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

    private func scheduleRefresh() {
        // The daemon needs a beat to write/remove its pidfile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
            self?.actionNote = nil
        }
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
}
