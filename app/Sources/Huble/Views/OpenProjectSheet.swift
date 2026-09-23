import SwiftUI

/// Open a vault folder that is already on this Mac (another drive, a
/// hand-made clone, a previous install): the installer re-inits it for this
/// machine and opens it in Obsidian.
struct OpenProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onRun: (InstallerAction) -> Void

    @State private var path = ""
    @State private var role = "cx"

    private var isVault: Bool { !path.isEmpty && VaultScanner.isVault(path) }
    private var recordedRole: String? { isVault ? VaultScanner.role(of: path) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open project from this Mac").font(.title2.weight(.semibold))
            Text("Choose a client vault folder that already exists on this Mac. It is set up for this machine and opened in Obsidian.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                LabeledContent("Vault folder") {
                    HStack {
                        Text(path.isEmpty ? "None chosen" : path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") {
                            if let p = FolderPicker.choose(startingAt: path.isEmpty ? model.state.effectiveVaultsDir : path,
                                                           message: "Choose the client vault folder") {
                                path = p
                            }
                        }
                    }
                }
                if !path.isEmpty && !isVault {
                    Label("This folder is not a Huble vault (no .huble/ or project-config.json).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if isVault {
                    if let r = recordedRole {
                        LabeledContent("Role") { RoleBadge(role: r) }
                    } else {
                        Picker("Your role", selection: $role) {
                            ForEach(hubleRoles, id: \.self) { Text($0.uppercased()).tag($0) }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") {
                    onRun(.openLocal(path: path, role: recordedRole == nil ? role : nil))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isVault)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            role = hubleRoles.contains(model.state.role ?? "") ? model.state.role! : "cx"
        }
    }
}
