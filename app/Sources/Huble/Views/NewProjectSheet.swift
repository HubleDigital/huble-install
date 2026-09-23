import SwiftUI

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onRun: (InstallerAction) -> Void

    @State private var client = ""
    @State private var role = "cx"
    @State private var folder = ""

    private var trimmed: String { client.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.hasPrefix(".")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New project").font(.title2.weight(.semibold))
            Form {
                TextField("Client name", text: $client)
                Picker("Your role", selection: $role) {
                    ForEach(hubleRoles, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                LabeledContent("Folder") { FolderField(folder: $folder) }
            }
            .formStyle(.grouped)
            Text("The vault is created at \(folder)/\(trimmed.isEmpty ? "<client>" : trimmed) and opened in Obsidian.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    onRun(.newProject(client: trimmed, role: role, vaultsDir: folder))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            role = hubleRoles.contains(model.state.role ?? "") ? model.state.role! : "cx"
            folder = model.state.effectiveVaultsDir
        }
    }
}
