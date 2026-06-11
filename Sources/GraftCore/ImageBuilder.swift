import Foundation

/// Builds a Tart image from an `ImageRecipe` — the same move as `RunnerProvisioner`,
/// but the result is kept (stopped) instead of run once: clone the base → boot (with
/// the recipe's mounts) → run the provisioning steps in the guest → stop → promote to
/// the named image. Tart clones are APFS copy-on-write, so the snapshot is cheap and
/// later clones (runners, `graft dev`) share its blocks.
public struct ImageBuilder: Sendable {
    private let provider: LocalTartProvider

    public init(provider: LocalTartProvider = LocalTartProvider()) {
        self.provider = provider
    }

    /// Build `recipe` into a local image named `recipe.name`. `onLine` receives the
    /// guest's build output live. A failure leaves any pre-existing image of that name
    /// untouched (the build happens on a throwaway clone first).
    /// `scriptBody`, if given (the contents of the recipe's `script:` file), runs before
    /// the inline `run` steps in the same guest shell.
    public func build(_ recipe: ImageRecipe, scriptBody: String? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws {
        let temp = "graft-imgbuild-" + UUID().uuidString.prefix(8).lowercased()
        try await Tart.clone(image: recipe.from, to: temp)
        do {
            try Tart.run(name: temp, mounts: recipe.mounts ?? [])
            let vm = RunningVM(name: temp, ip: "", os: recipe.guestOS)
            try await provider.waitForGuest(vm, timeout: .seconds(120))

            if let provisioning = recipe.provisioning(scriptBody: scriptBody) {
                let exit = try await provider.execStreaming(on: vm, script: provisioning, onLine: onLine)
                guard exit == 0 else { throw GraftError("image build step failed (exit \(exit))") }
            }

            try await Tart.stop(name: temp)

            // Promote: replace any existing image of this name with the freshly-built
            // one (CoW clone, ~instant), then drop the throwaway.
            if try await Tart.exists(name: recipe.name) {
                try await Tart.delete(name: recipe.name)
            }
            try await Tart.clone(image: temp, to: recipe.name)
            try await Tart.delete(name: temp)
        } catch {
            try? await Tart.stop(name: temp)
            try? await Tart.delete(name: temp)
            throw error
        }
    }

}
