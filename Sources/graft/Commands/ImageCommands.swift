import ArgumentParser
import Foundation
import GraftCore

/// `graft image …` — build and manage Tart images (the golden VMs that runners and
/// `graft dev` clone from).
struct Image: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Build and manage Tart images.",
        subcommands: [Build.self, List.self, Remove.self, Push.self, Pull.self, Template.self]
    )
}

extension Image {
    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Build an image from a JSON recipe.")

        @Option(name: .shortAndLong, help: "Recipe file (JSON). See `graft image template`.")
        var file: String

        @Option(name: .long, help: "Override the image name from the recipe.")
        var name: String?

        func run() async throws {
            var recipe = try ImageRecipe.load(from: file)
            if let name {
                recipe = ImageRecipe(name: name, from: recipe.from, run: recipe.run, script: recipe.script, mounts: recipe.mounts, os: recipe.os)
            }

            // Read the recipe's `script:` file, resolved relative to the recipe's dir.
            var scriptBody: String?
            if let scriptRef = recipe.script {
                let recipeDir = ((file as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
                let raw = scriptRef.hasPrefix("/") ? scriptRef : (recipeDir as NSString).appendingPathComponent(scriptRef)
                let path = (raw as NSString).expandingTildeInPath
                guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw GraftError("can't read recipe script at \(path)")
                }
                scriptBody = body
            }

            printErr("building image '\(recipe.name)' from \(recipe.from)…\n")
            try await ImageBuilder().build(recipe, scriptBody: scriptBody) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            printErr("\n✓ built '\(recipe.name)' — reference it in a pool's `image`, or `graft dev --image \(recipe.name)`")
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

        @Argument(help: "Registry ref, e.g. ghcr.io/cirruslabs/macos-sequoia-xcode:latest")
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
