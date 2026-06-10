import Foundation

/// Installs and runs the ephemeral GitHub Actions runner inside a VM via the
/// provider's exec channel (no SSH). With JIT config there's no `config.sh` step —
/// the runner registers, runs one job, self-deregisters, and exits. We just stream
/// its logs and wait for that exit.
public struct RunnerProvisioner: Sendable {
    private let provider: any VMProvider

    public init(provider: any VMProvider) {
        self.provider = provider
    }

    /// Wait for the guest, then run the ephemeral runner with `jitConfig`. Blocks
    /// until the runner's single job finishes; returns its exit code.
    public func runEphemeralRunner(on vm: RunningVM, jitConfig: String) async throws -> Int32 {
        try await provider.waitForGuest(vm)
        let script = Self.provisionScript(os: vm.os, jitConfig: jitConfig)
        return try await provider.execStreaming(on: vm, script: script)
    }

    /// The bash run inside the guest. Uses a pre-baked runner at `~/actions-runner`
    /// if present (cirruslabs runner images ship one), otherwise downloads the
    /// latest release. Version is fetched, never hardcoded.
    ///
    /// TODO(real-VM): confirm on a booted VM — (1) the runner dir path on cirruslabs
    /// images, (2) the release asset naming, (3) that `bash -s` over `tart exec`
    /// propagates the runner's exit code. Built from the design doc; unverified
    /// against a live guest.
    static func provisionScript(os: GuestOS, jitConfig: String) -> String {
        let arch: String
        switch os {
        case .macOS: arch = "osx-arm64"      // Tart guests on Apple Silicon are arm64
        case .linux: arch = "linux-arm64"
        }
        // jitConfig is base64 (no single quotes), so single-quoting is safe.
        return """
        set -euo pipefail
        RUNNER_DIR="$HOME/actions-runner"
        JITCONFIG='\(jitConfig)'

        if [ ! -x "$RUNNER_DIR/run.sh" ]; then
          echo "graft: no pre-baked runner, downloading latest…"
          mkdir -p "$RUNNER_DIR"
          cd "$RUNNER_DIR"
          VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
            | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\\1/')"
          curl -fsSL -o runner.tar.gz \
            "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-\(arch)-${VERSION}.tar.gz"
          tar xzf runner.tar.gz
          rm -f runner.tar.gz
        fi

        cd "$RUNNER_DIR"
        echo "graft: starting ephemeral runner…"
        exec ./run.sh --jitconfig "$JITCONFIG"
        """
    }
}
