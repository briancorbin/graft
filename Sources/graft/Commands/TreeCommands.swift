import ArgumentParser
import Foundation
import GraftCore

/// `graft tree …` — inspect the tree: the **trunk** (controller) plus its **branches**
/// (worker Macs) that your **leaves** (runner VMs) grow on. Backend-agnostic — the
/// orchestrator vendor's name lives only in `provider: "orchard"` config, never here.
///
/// Setup happens in `graft init` (pick the Orchard backend); these commands operate the
/// tree it points at. (`plant`/`branch`/`prune` for trunk+worker lifecycle land next.)
struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Plant, tend, and inspect the tree — trunk, branches, and leaves.",
        subcommands: [Plant.self, Branch.self, Prune.self, Status.self, Branches.self, Leaves.self]
    )
}

// MARK: - Shared

extension Tree {
    /// Default trunk data dir + where we stash the one-time bootstrap-admin token the
    /// controller prints on first run, so `branch`/`prune` can authenticate later.
    static var dataDir: String { (NSHomeDirectory() as NSString).appendingPathComponent(".orchard/controller") }
    static var adminTokenFile: String { (NSHomeDirectory() as NSString).appendingPathComponent(".orchard/admin-token.txt") }
    static let workerAccount = "graft-workers"

    /// Fail early with an install hint if the `orchard` CLI isn't on PATH.
    static func requireOrchard() async throws {
        guard let r = try? await Shell.run("orchard", ["--version"]), r.succeeded else {
            throw GraftError("`orchard` not found on PATH — install it with `brew install cirruslabs/cli/orchard`")
        }
    }

    /// Strip ANSI escape codes from a line (the controller colorizes its startup banner).
    static func stripANSI(_ s: String) -> String {
        var out = "", inEscape = false
        for ch in s {
            if inEscape {
                if ch.isLetter { inEscape = false }   // CSI sequence ends at a letter
            } else if ch == "\u{1B}" {
                inEscape = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Admin auth env for a trunk, from the stored bootstrap-admin token. Throws with a
    /// clear hint when it's missing (you planted elsewhere, or need admin yourself).
    static func adminEnv(url: String) throws -> [String: String] {
        guard let token = try? String(contentsOfFile: adminTokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw GraftError("no admin token at \(adminTokenFile) — plant the trunk here first (`graft tree plant`), or pass a bootstrap token explicitly")
        }
        var env = ProcessInfo.processInfo.environment
        env[OrchardEnv.url] = url
        env[OrchardEnv.accountName] = "bootstrap-admin"
        env[OrchardEnv.accountToken] = token
        return env
    }

    /// Build an `OrchardProvider` from a profile's orchard block, resolving the token
    /// from the Keychain when it isn't inline (same order as `graft run`).
    static func provider(profile: String?) throws -> OrchardProvider {
        let name = try resolveProfileName(profile)
        let cfg = try Profiles.load(name)
        guard var orchard = cfg.orchard else {
            throw GraftError("profile '\(name)' has no tree configured — run `graft init` and choose the Orchard backend")
        }
        if (orchard.token ?? "").isEmpty {
            let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login
            orchard.token = KeychainSecretStore(scope: scope).orchardToken(account: orchard.serviceAccount)
        }
        return OrchardProvider(config: orchard)
    }

    /// Start a detection-only host-vitals monitor alongside a long-running tree process (a
    /// branch worker or the trunk controller). Sink/webhook config comes from the active
    /// profile when there is one, else defaults. Returns the task so the caller cancels it
    /// when the orchard process exits.
    static func startHostMonitor(_ detectors: [any HealthDetector], profile: String? = nil) -> Task<Void, Never> {
        let mon = ((try? resolveProfileName(profile)).flatMap { try? Profiles.load($0) })?.monitor ?? MonitorConfig()
        let reporter = HealthReporter(sinks: HealthMonitorFactory.sinks(monitor: mon))
        let heartbeat = mon.heartbeatSeconds
        let monitor = HealthMonitor(
            detectors: detectors, reporter: reporter,
            interval: .seconds(mon.intervalSeconds),
            heartbeatSeconds: heartbeat > 0 ? TimeInterval(heartbeat) : nil)
        printErr(ANSI.dim("    tending: \(detectors.count) host detectors, \(mon.webhooks.count) webhook(s) — detection-only"))
        return Task { await monitor.run() }
    }
}

// MARK: - graft tree status / branches / leaves

extension Tree {
    /// One-glance tree health: trunk, branch count, free capacity, graft's leaves.
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show tree health (trunk, branches, free capacity).")

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        func run() async throws {
            let report = try await Tree.provider(profile: profile).report()
            let paused = report.workers.filter(\.paused).count
            print("trunk:     \(report.controllerURL)")
            print("branches:  \(report.workers.count)\(paused > 0 ? "  (\(paused) paused)" : "")")
            print("capacity:  \(report.totalSlots) slots · \(report.usedVMs) used · \(report.freeSlots) free")
            print("leaves:    \(report.graftVMNames.count)")
        }
    }

    /// Per-branch view with advertised slots, plus the tree's free-slot total.
    struct Branches: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the branches (workers) and their leaf capacity.")

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        func run() async throws {
            let report = try await Tree.provider(profile: profile).report()
            guard !report.workers.isEmpty else {
                printErr("no branches yet — graft one on with `graft tree branch <trunk-url>`")
                return
            }
            let width = report.workers.map { $0.name.count }.max() ?? 8
            print("\(pad("BRANCH", width))  PAUSED  LEAVES")
            for w in report.workers {
                print("\(pad(w.name, width))  \(pad(w.paused ? "yes" : "no", 6))  \(w.slots)")
            }
            printErr(ANSI.dim("— tree: \(report.freeSlots) free / \(report.totalSlots) slots (\(report.usedVMs) used)"))
        }

        private func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
    }

    /// Leaves (VMs) on the tree — graft's by default, the whole cluster with `--all`.
    struct Leaves: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the leaves (VMs) on the tree (graft's by default).")

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        @Flag(help: "Show every leaf on the cluster, not just graft's.")
        var all = false

        func run() async throws {
            let listing = try await Tree.provider(profile: profile).rawList("vms")
            let lines = listing.split(whereSeparator: \.isNewline).map(String.init)
            guard let header = lines.first else { printErr("no leaves"); return }
            let rows = all
                ? Array(lines.dropFirst())
                : lines.dropFirst().filter { $0.hasPrefix("graft-") }
            guard !rows.isEmpty else {
                printErr(all ? "no leaves" : "no graft leaves (try --all)")
                return
            }
            print(header)
            rows.forEach { print($0) }
        }
    }
}

// MARK: - graft tree plant / branch / prune  (trunk + branch lifecycle)

extension Tree {
    /// Plant the trunk: run the controller in the foreground. On first run the controller
    /// prints a one-time `bootstrap-admin` token — we capture it so `branch`/`prune` can
    /// authenticate. (HTTP-only for now; TLS is a future option.)
    struct Plant: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Plant the trunk — run the controller (foreground).")

        @Option(name: .long, help: "Controller data directory (state + accounts persist here).")
        var dataDir: String = Tree.dataDir

        @Flag(name: .long, help: "Bonsai: a tiny local tree — trunk + one branch on this machine (for testing).")
        var bonsai = false

        @Flag(name: .long, help: "Also tend this trunk: host-vitals + controller-responding monitoring (detection-only).")
        var tend = false

        func run() async throws {
            try await Tree.requireOrchard()
            try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

            // Optional controller-host monitor: disk/memory + is the controller answering?
            let monitorTask: Task<Void, Never>? = tend ? Tree.startHostMonitor(
                HealthMonitorFactory.controllerDetectors(name: ProcessInfo.processInfo.hostName, responding: {
                    // Token is captured a beat after the controller starts — treat "not yet" as healthy.
                    guard let env = try? Tree.adminEnv(url: "http://127.0.0.1:6120") else { return true }
                    return ((try? await Shell.run("orchard", ["list", "workers"], environment: env, timeout: .seconds(10)))?.succeeded) ?? false
                })) : nil
            defer { monitorTask?.cancel() }

            if bonsai { try await plantBonsai(); return }

            printErr(ANSI.green("🕳  digging a hole…"))
            printErr(ANSI.green("🌱  planting the trunk…") + ANSI.dim("   (Ctrl-C to stop)"))
            printErr(ANSI.dim("    data: \(dataDir)\n"))
            let code = try await runTrunk()
            if code != 0 { throw ExitCode(code) }
        }

        /// A **bonsai** — a tiny self-contained tree: the trunk plus one branch, both on
        /// this machine, for local testing. Runs them as separate processes (not the
        /// wedge-prone fused `orchard dev`): the trunk in the foreground, a branch grafted
        /// on in the background once the trunk is up. Ctrl-C stops both (shared group).
        private func plantBonsai() async throws {
            printErr(ANSI.green("🪴  potting a bonsai — a local trunk + branch…") + ANSI.dim("   (Ctrl-C to stop)\n"))
            let url = "http://127.0.0.1:6120"
            let tokenFile = Tree.adminTokenFile

            // Once the trunk is listening + the admin token is captured, graft a branch on.
            let branch = Task {
                for _ in 0..<90 where (try? String(contentsOfFile: tokenFile))?.isEmpty != false {
                    try? await Task.sleep(for: .seconds(1))
                }
                try? await Task.sleep(for: .seconds(1))
                do {
                    let boot = try await Tree.mintBootstrapToken(url: url)
                    printErr(ANSI.green("🌿  grafting a branch on…\n"))
                    _ = try await Shell.runStreaming(
                        "orchard", ["worker", "run", url, "--bootstrap-token", boot, "--name", "bonsai"],
                        onLine: { line in FileHandle.standardError.write(Data(("[branch] " + line + "\n").utf8)) }
                    )
                } catch is CancellationError {
                } catch {
                    printErr(ANSI.yellow("  branch failed: \(error)"))
                }
            }
            defer { branch.cancel() }

            printErr(ANSI.green("🕳  digging a hole… 🌱 planting the trunk…\n"))
            let code = try await runTrunk(prefix: "[trunk] ")
            branch.cancel()
            if code != 0 { throw ExitCode(code) }
        }

        /// Run the controller in the foreground, echoing its logs (optionally prefixed) and
        /// capturing the one-time bootstrap-admin token so `branch`/`prune` can authenticate.
        private func runTrunk(prefix: String = "") async throws -> Int32 {
            let tokenFile = Tree.adminTokenFile
            return try await Shell.runStreaming(
                "orchard",
                ["controller", "run", "--insecure-no-tls", "--insecure-ssh-no-client-auth", "--data-dir", dataDir],
                onLine: { line in
                    FileHandle.standardError.write(Data((prefix + line + "\n").utf8))
                    let clean = Tree.stripANSI(line)
                    if let r = clean.range(of: "Service account token:") {
                        let tok = clean[r.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !tok.isEmpty { try? tok.write(toFile: tokenFile, atomically: true, encoding: .utf8) }
                    }
                }
            )
        }
    }

    /// Graft a branch on: run a worker on THIS Mac that joins the tree. Mints a bootstrap
    /// token from the trunk (needs you to have planted it here) unless one is passed.
    struct Branch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Graft a branch on — run a worker that joins the tree.")

        @Argument(help: "Trunk (controller) URL to join, e.g. http://trunk.local:6120")
        var url: String

        @Option(name: .long, help: "Bootstrap token (default: mint one — needs the trunk planted here).")
        var token: String?

        @Option(name: .long, help: "Branch (worker) name (default: this host's name).")
        var name: String?

        @Option(name: .long, help: "Labels, comma-separated key=value (e.g. hardware=m4max).")
        var labels: String?

        @Option(name: .long, help: "Reserve N GB of host RAM: advertise (total − N) to the scheduler so leaves can't OOM the host.")
        var reserve: Int?

        @Flag(name: .long, help: "Also tend this branch: host-vitals monitoring (disk/memory/tart, detection-only).")
        var tend = false

        func run() async throws {
            try await Tree.requireOrchard()
            printErr(ANSI.green("🌿  grafting a branch onto \(url)…"))
            let boot: String
            if let token { boot = token } else { boot = try await Tree.mintBootstrapToken(url: url) }
            var args = ["worker", "run", url, "--bootstrap-token", boot]
            if let name { args += ["--name", name] }
            if let labels {
                for kv in labels.split(separator: ",") { args += ["--labels", kv.trimmingCharacters(in: .whitespaces)] }
            }
            if let reserve {
                // Advertise (RAM − reserve) so the scheduler keeps a host buffer. Re-state
                // the auto-detected resources too so overriding memory doesn't drop them.
                let totalMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
                let mib = max(1024, totalMB - reserve * 1024)
                args += ["--resources", "org.cirruslabs.memory-mib=\(mib)"]
                args += ["--resources", "org.cirruslabs.tart-vms=2"]
                args += ["--resources", "org.cirruslabs.logical-cores=\(ProcessInfo.processInfo.activeProcessorCount)"]
                printErr(ANSI.dim("    advertising \(mib) MB (reserving \(reserve) GB for the host)"))
            }
            let monitorTask: Task<Void, Never>? = tend
                ? Tree.startHostMonitor(HealthMonitorFactory.branchDetectors(name: name ?? ProcessInfo.processInfo.hostName))
                : nil
            defer { monitorTask?.cancel() }

            printErr(ANSI.dim("    branch live — Ctrl-C to drop it.\n"))
            let code = try await Shell.runStreaming("orchard", args, onLine: { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            })
            if code != 0 { throw ExitCode(code) }
        }
    }

    /// Prune a branch: deregister a worker from the trunk. Needs admin (the stored
    /// bootstrap-admin token from a local `plant`).
    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Prune a branch — remove a worker from the tree.")

        @Argument(help: "Branch (worker) name to remove.")
        var name: String

        @Option(name: .long, help: "Trunk URL (default: the profile's controllerURL).")
        var url: String?

        @Option(name: .long, help: "Profile to read the trunk URL from (default: active).")
        var profile: String?

        func run() async throws {
            try await Tree.requireOrchard()
            let trunk: String
            if let url {
                trunk = url
            } else {
                let profileName = try resolveProfileName(profile)
                guard let u = (try Profiles.load(profileName)).orchard?.controllerURL.absoluteString else {
                    throw GraftError("profile '\(profileName)' has no trunk URL — pass --url")
                }
                trunk = u
            }
            let env = try Tree.adminEnv(url: trunk)
            let result = try await Shell.run("orchard", ["delete", "worker", name], environment: env, timeout: .seconds(20))
            guard result.succeeded else {
                throw GraftError("couldn't prune '\(name)': \(result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed)")
            }
            printErr(ANSI.green("✂️  pruned branch '\(name)'"))
        }
    }

    /// Mint a worker bootstrap token from the trunk (ensures the worker service account
    /// exists first). Uses the stored admin token, so the trunk must have been planted here.
    static func mintBootstrapToken(url: String) async throws -> String {
        let env = try adminEnv(url: url)
        _ = try? await Shell.run("orchard", [
            "create", "service-account", workerAccount,
            "--roles", "compute:read", "--roles", "compute:write", "--roles", "compute:connect",
        ], environment: env, timeout: .seconds(20))
        let result = try await Shell.run("orchard", ["get", "bootstrap-token", workerAccount], environment: env, timeout: .seconds(20))
        guard result.succeeded, !result.stdoutTrimmed.isEmpty else {
            throw GraftError("couldn't mint a bootstrap token: \(result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed)")
        }
        return result.stdoutTrimmed
    }
}
