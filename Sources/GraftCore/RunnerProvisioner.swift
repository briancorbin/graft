import Foundation

/// Builds the bootstrap script that launches the ephemeral GitHub Actions runner inside a
/// leaf. The script is handed to the leaf at create time — Orchard runs it as the VM's
/// StartupScript (the *worker*, local to the VM), local Tart runs it via `tart exec` — so the
/// supervisor never execs into the guest. With JIT config there's no `config.sh`: the runner
/// registers, runs one job, self-deregisters, and exits. We launch it **detached** so it
/// survives the launching session closing, then the supervisor watches it via GitHub.
public enum RunnerProvisioner {
    /// The bash run inside the guest. Uses a pre-baked runner at `~/actions-runner` if
    /// present (a properly-baked sapling ships one), otherwise downloads the latest release.
    /// The final launch is detached (`nohup … & disown`, portable across macOS — which has no
    /// `setsid` — and Linux) so it outlives the worker's/host's exec session.
    public static func provisionScript(os: GuestOS, jitConfig: String) -> String {
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
        echo "graft: launching ephemeral runner (detached)…"
        nohup ./run.sh --jitconfig "$JITCONFIG" >"$RUNNER_DIR/runner.log" 2>&1 </dev/null &
        disown
        echo "graft: runner launched (pid $!)"
        """
    }
}
