import ArgumentParser
import Foundation
import GraftCore

@main
struct Graft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graft",
        abstract: "Ephemeral GitHub Actions runners on Tart VMs.",
        version: "0.2.0",
        subcommands: [
            Init.self, Run.self, Status.self, Stop.self, Arborist.self,
            Profile.self, Pool.self, Leaf.self, ConfigCommand.self, Secrets.self,
            Runners.self, Image.self, Dev.self, Tree.self,
        ]
    )
}

/// Let `--os macos|linux` parse straight into `GuestOS`.
extension GuestOS: ExpressibleByArgument {
    public init?(argument: String) { self.init(rawValue: argument.lowercased()) }
}

/// Write a line to stderr (progress, warnings, errors) — keeps stdout clean for
/// machine-readable output like `graft leaf create`'s `name<TAB>ip`.
func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
