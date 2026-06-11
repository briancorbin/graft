import SwiftUI
import GraftCore

/// The menu-bar dropdown content. Status at a glance + the actions you actually
/// reach for: switch profile, start/stop.
struct MenuContentView: View {
    @ObservedObject var controller: GraftController

    private var busy: Bool { controller.actionNote != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            profileSwitcher

            if let note = controller.actionNote {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Divider()
            runnerList
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 260)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(controller.isRunning ? "Running" : "Stopped")
                .font(.headline)
            Spacer()
            if controller.isRunning {
                Text("\(controller.runners.count) runner\(controller.runners.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileSwitcher: some View {
        if controller.profiles.isEmpty {
            Text("No profiles — run graft init")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(controller.profiles, id: \.self) { name in
                    Button {
                        controller.useProfile(name)
                    } label: {
                        if name == controller.activeProfile {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                Label("Profile: \(controller.activeProfile ?? "—")", systemImage: "square.stack.3d.up")
            }
            .disabled(busy)
        }
    }

    @ViewBuilder
    private var runnerList: some View {
        if controller.runners.isEmpty {
            Text("No active runners")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(controller.runners, id: \.vm.name) { runner in
                HStack {
                    Text(runner.pool).font(.subheadline)
                    Spacer()
                    Text(runner.vm.ip).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.graftInstalled {
                Text("graft CLI not found")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            HStack {
                if controller.isRunning {
                    // Enabled during boot (so you can cancel), disabled only while
                    // already tearing down (no double-stop).
                    Button("Stop") { controller.stop() }.disabled(controller.isStopping)
                } else {
                    Button("Start") { controller.start() }
                        .disabled(busy || !controller.graftInstalled)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
    }
}
