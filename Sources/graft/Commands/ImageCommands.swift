import ArgumentParser
import Foundation
import GraftCore

/// `graft sapling …` — grow and manage saplings (the golden images that leaves and
/// nests clone from). A sapling grows from a `.graft` seed.
struct Image: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sapling",
        abstract: "Grow and manage saplings — the golden images leaves clone from.",
        subcommands: [Build.self, Render.self, List.self, Remove.self, Prune.self, Push.self, Pull.self, Template.self]
    )
}

/// Resolve a recipe's `script:` file relative to the recipe path, returning its body.
func recipeScriptBody(_ recipe: ImageRecipe, recipeFile: String) throws -> String? {
    guard let scriptRef = recipe.script else { return nil }
    let recipeDir = ((recipeFile as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
    let raw = scriptRef.hasPrefix("/") ? scriptRef : (recipeDir as NSString).appendingPathComponent(scriptRef)
    let path = (raw as NSString).expandingTildeInPath
    guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw GraftError("can't read recipe script at \(path)")
    }
    return body
}

extension Image {
    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "grow",
            abstract: "Grow a sapling from a .graft seed (also YAML / JSON)."
        )

        @Option(name: .shortAndLong, help: "Seed file (.graft / .yml / .json). See `graft sapling template`.")
        var seed: String

        @Option(name: .long, help: "Override the sapling name from the seed.")
        var name: String?

        func run() async throws {
            var recipe = try ImageRecipe.load(from: seed)
            if let name { recipe.name = name }

            let scriptBody = try recipeScriptBody(recipe, recipeFile: seed)
            printErr("growing sapling '\(recipe.name)' from \(recipe.from)…\n")
            try await ImageBuilder().build(recipe, scriptBody: scriptBody) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            printErr("\n✓ grew '\(recipe.name)' — reference it in a pool's `image`, or `graft nest --image \(recipe.name)`")
        }
    }

    struct Render: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the provisioning script a recipe compiles to (no build).")

        @Option(name: .shortAndLong, help: "Recipe file (.graft / .yml / .json).")
        var file: String

        func run() throws {
            let recipe = try ImageRecipe.load(from: file)
            let scriptBody = try recipeScriptBody(recipe, recipeFile: file)
            print("# image '\(recipe.name)' from \(recipe.from)")
            print(recipe.provisioning(scriptBody: scriptBody) ?? "# (nothing to provision)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List local images and VMs.")

        func run() async throws {
            let vms = try await Tart.list()
            guard !vms.isEmpty else { printErr("no images"); return }
            for vm in vms.sorted(by: { $0.name < $1.name }) {
                let size = vm.size.map { "\($0)G" } ?? "-"
                print("\(vm.name)\t\(vm.source ?? "-")\t\(size)\t\(vm.state)")
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a local image/VM.")

        @Argument(help: "Image (VM) name.")
        var name: String

        func run() async throws {
            try? await Tart.stop(name: name)
            guard try await Tart.exists(name: name) else { throw GraftError("no image named '\(name)'") }
            try await Tart.delete(name: name)
            printErr("✓ removed '\(name)'")
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove leftover throwaway build VMs from failed builds.")

        @Flag(help: "Also remove *running* build VMs — may kill an in-progress build.")
        var force = false

        func run() async throws {
            let temps = (try? await Tart.list())?.filter { ImageBuilder.isOrphanTemp($0.name) } ?? []
            guard !temps.isEmpty else { printErr("no orphaned build VMs"); return }
            // Skip running temps by default — a running graft-imgbuild is most likely an
            // active build, not a leftover.
            let removed = await ImageBuilder().sweepOrphans(includeRunning: force)
            printErr("✓ pruned \(removed.count) orphaned build VM(s)")
            let skipped = temps.filter { $0.isRunning && !removed.contains($0.name) }
            if !skipped.isEmpty {
                printErr("⚠ skipped \(skipped.count) running build VM(s) (likely an active build) — `graft image prune --force` to remove: \(skipped.map(\.name).joined(separator: ", "))")
            }
        }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Push a local image to a registry.")

        @Argument(help: "Local image name.")
        var name: String

        @Argument(help: "Registry ref, e.g. ghcr.io/me/rn-detox:latest")
        var ref: String

        func run() async throws {
            printErr("pushing '\(name)' → \(ref)…")
            try await Tart.push(name: name, to: ref)
            printErr("✓ pushed")
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pull an image from a registry.")

        @Argument(help: "Registry ref, e.g. ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        var ref: String

        func run() async throws {
            printErr("pulling \(ref)…")
            try await Tart.pull(ref: ref)
            printErr("✓ pulled \(ref)")
        }
    }

    struct Template: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a starter image recipe.")

        func run() {
            print(ImageRecipe.template())
        }
    }
}
