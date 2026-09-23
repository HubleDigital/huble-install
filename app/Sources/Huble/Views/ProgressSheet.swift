import AppKit
import SwiftUI

struct ProgressSheet: View {
    let run: InstallerRun
    let onClose: () -> Void
    /// Offered when a remove failed with `reason: unsynced`: the user has read
    /// the warning and chooses to lose the unsynced work.
    var onRemoveAnyway: (() -> Void)? = nil

    @State private var showLog = false
    @State private var confirmForce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(run.action.title).font(.title2.weight(.semibold))
                Spacer()
                if run.isRunning { ProgressView().controlSize(.small) }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(run.steps) { step in
                            StepView(step: step, isCurrent: step.id == run.steps.last?.id)
                                .id(step.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: run.steps.count) { _, _ in
                    if let last = run.steps.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(minHeight: 200, maxHeight: 320)

            if let code = run.ghAuthCode, let urlString = run.ghAuthURL {
                GitHubAuthCard(code: code, urlString: urlString)
            }

            switch run.status {
            case .failed(let msg):
                Label(msg, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case .cancelled:
                Label("Cancelled.", systemImage: "stop.circle").foregroundStyle(.secondary)
            case .succeeded:
                Label(run.vaultPath.map { "Done — \($0)" } ?? "Done.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .running:
                EmptyView()
            }

            DisclosureGroup("Show log", isExpanded: $showLog) {
                ScrollView {
                    Text(run.eventLog + (run.log.isEmpty ? "" : "\n--- stderr ---\n" + run.log))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }

            HStack {
                Spacer()
                if run.isRunning {
                    Button("Cancel") { run.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    if run.failReason == "unsynced", let onRemoveAnyway {
                        Button("Remove anyway…", role: .destructive) { confirmForce = true }
                            .confirmationDialog("Remove it and lose the unsynced work?", isPresented: $confirmForce, titleVisibility: .visible) {
                                Button("Move to Trash anyway", role: .destructive) { onRemoveAnyway() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Changes that were never synced to GitHub exist only in this folder. They go to the Trash with it.")
                            }
                    }
                    Button("Close") { onClose() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(run.isRunning)
    }
}

private struct StepView: View {
    let step: InstallerRun.Step
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                icon.frame(width: 16)
                Text(step.title).font(.body.weight(isCurrent ? .semibold : .regular))
            }
            ForEach(step.notes) { note in
                HStack(alignment: .top, spacing: 6) {
                    Text(prefix(note.kind)).frame(width: 16)
                    Text(note.text).textSelection(.enabled)
                }
                .font(.callout)
                .foregroundStyle(color(note.kind))
                .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func prefix(_ k: InstallerRun.NoteKind) -> String {
        switch k {
        case .ok: return "✓"
        case .note: return "·"
        case .warn: return "!"
        case .error: return "✗"
        }
    }

    private func color(_ k: InstallerRun.NoteKind) -> Color {
        switch k {
        case .ok: return .secondary
        case .note: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }
}

private struct GitHubAuthCard: View {
    let code: String
    let urlString: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in to GitHub").font(.headline)
            Text("Enter this code on the GitHub page that opened, then come back here. The installer continues by itself.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(code)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                Button("Open GitHub") {
                    if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
