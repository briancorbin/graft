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
        abstract: "Inspect the tree — trunk, branches, and the leaves growing on it.",
        subcommands: [Status.self, Branches.self, Leaves.self]
    )
}

// MARK: - Shared

extension Tree {
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
