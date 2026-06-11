import ArgumentParser
import Foundation
import GraftCore

/// `graft dev` — spin up a local dev VM from an image with your repo host-mounted.
/// Persistent by default (reattach across sessions, deps/build artifacts persist on
/// the VM's disk); `--ephemeral` for a throwaway. Drops you into a shell in the repo,
/// or runs a command and exits.
struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Boot a dev VM from an image with your repo mounted; shell in or run a command."
    )

    @Option(name: .long, help: "Image to clone from (default: pick from local images).")
    var image: String?

    @Option(name: .long, help: "Dev VM name (default: derived from the image).")
    var name: String?

    @Option(name: .long, parsing: .singleValue, help: "Extra mount: path | name:path | name:path:ro (repeatable).")
    var mount: [String] = []

    @Flag(name: .long, help: "Don't mount the current directory as 'repo'.")
    var noRepo = false

    @Flag(help: "Throwaway VM: fresh clone, deleted on exit (default: persistent).")
    var ephemeral = false

    @Argument(parsing: .postTerminator, help: "Command after `--` to run in the VM (default: interactive shell).")
    var command: [String] = []

    func run() async throws {
        let provider = LocalTartProvider()
        let img: String
        if let image { img = image } else { img = await ImagePicker.resolve() }

        // Mounts: $PWD as "repo" (RW) unless suppressed, plus any extras.
        var mounts: [Mount] = []
        if !noRepo { mounts.append(Mount(name: "repo", source: FileManager.default.currentDirectoryPath)) }
        mounts += try mount.map { try Mount(spec: $0) }
        let repoGuestPath = mounts.first { $0.name == "repo" }?.guestPath

        // Capacity heads-up (macOS 2-VM limit), counting *other* running graft VMs.
        let vmName = ephemeral
            ? "graft-dev-eph-" + UUID().uuidString.prefix(8).lowercased()
            : (name ?? Self.devName(for: img))
        let running = (try? await Tart.list())?.filter {
            $0.name.hasPrefix("graft-") && $0.isRunning && $0.name != vmName
        } ?? []
        if running.count >= LocalTartProvider.hostCapacity(for: .macOS) {
            printErr("⚠ \(running.count) other graft VM(s) running — at the macOS 2-VM limit; this may fail to boot.")
        }

        // Clone if missing; boot (with mounts) unless already running.
        let existing = try await Tart.list().first { $0.name == vmName }
        if existing == nil {
            printErr("cloning \(img) → \(vmName)…")
            try await Tart.clone(image: img, to: vmName)
        }
        if existing?.isRunning != true {
            printErr("booting \(vmName)…")
            try Tart.run(name: vmName, mounts: mounts)
            try await provider.waitForGuest(RunningVM(name: vmName, ip: "", os: .macOS), timeout: .seconds(120))
        } else if !mount.isEmpty || !noRepo {
            printErr("(reattaching to running \(vmName) — using the mounts it booted with)")
        }

        if repoGuestPath != nil {
            printErr("repo mounted at \(repoGuestPath!)")
        }

        // Run the command (or an interactive shell), in the repo dir when mounted.
        // A shell needs stdin forwarding (-i); a one-shot command must not (it would
        // block on a non-TTY stdin).
        let exit = try Tart.execInteractive(
            name: vmName,
            command: Self.shell(cd: repoGuestPath, run: command),
            interactive: command.isEmpty
        )

        if ephemeral {
            printErr("\ntearing down \(vmName)…")
            try? await Tart.stop(name: vmName)
            try? await Tart.delete(name: vmName)
        } else {
            printErr("\n\(vmName) left running — `graft dev` to reattach, `graft vm delete \(vmName)` to remove.")
        }
        if exit != 0 { throw ExitCode(exit) }
    }

    /// Build the bash invocation: cd into the mounted repo (if any), then either run
    /// the passthrough command or replace with an interactive login shell.
    private static func shell(cd: String?, run: [String]) -> [String] {
        let prefix = cd.map { "cd '\($0)' 2>/dev/null; " } ?? ""
        let body = run.isEmpty ? "exec bash -l" : run.joined(separator: " ")
        return ["bash", "-lc", prefix + body]
    }

    /// `ghcr.io/cirruslabs/macos-sequoia-xcode:latest` → `graft-dev-macos-sequoia-xcode`.
    private static func devName(for image: String) -> String {
        let base = image.split(separator: "/").last.map(String.init) ?? image
        let noTag = base.split(separator: ":").first.map(String.init) ?? base
        let safe = String(noTag.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") ? $0 : "-" })
        return "graft-dev-" + (safe.isEmpty ? "vm" : safe)
    }
}
