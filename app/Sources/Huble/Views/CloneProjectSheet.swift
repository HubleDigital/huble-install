import SwiftUI

/// Clone a client vault from GitHub: the org repos tagged as vaults, or a
/// typed owner/name.
struct CloneProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onRun: (InstallerAction) -> Void

    @State private var vaults: [RemoteVault] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var selected: RemoteVault?
    @State private var manualRepo = ""
    @State private var role = "cx"
    @State private var folder = ""

    private var filtered: [RemoteVault] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return vaults }
        return vaults.filter { $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    /// Manual entry is `owner/name` or a bare name in the default org.
    private var repo: String? {
        if let s = selected { return s.nameWithOwner }
        let m = manualRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !m.hasPrefix("/"), !m.hasSuffix("/") else { return nil }
        return m.contains("/") ? m : "\(RemoteVaults.org)/\(m)"
    }

    /// The local vault whose git origin is this repo (contract rule: origin
    /// owner/name, never the folder name).
    private func localCopy(of repo: String) -> LocalVault? {
        model.vaults.first { $0.origin == repo.lowercased() }
    }
    private var existingLocal: LocalVault? { repo.flatMap(localCopy) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone project from GitHub").font(.title2.weight(.semibold))

            TextField("Search client vaults", text: $search)
                .textFieldStyle(.roundedBorder)

            Group {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Loading client vaults from GitHub…") }
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let error {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button("Retry") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity)
                } else if filtered.isEmpty {
                    Text(vaults.isEmpty ? "No client vaults found (repos need the topic “\(RemoteVaults.topic)”)." : "No match.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    List(filtered, selection: $selected) { v in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name).font(.body.weight(.medium))
                                if let d = v.description {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if localCopy(of: v.nameWithOwner) != nil {
                                Text("On this Mac")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.18))
                                    .clipShape(Capsule())
                            }
                        }
                        .tag(v)
                    }
                }
            }
            .frame(height: 220)

            Form {
                TextField("Or enter a repo (owner/name)", text: $manualRepo)
                    .onChange(of: manualRepo) { _, v in if !v.isEmpty { selected = nil } }
                Picker("Your role", selection: $role) {
                    ForEach(hubleRoles, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                LabeledContent("Clone into") { FolderField(folder: $folder) }
            }
            .formStyle(.grouped)

            if let local = existingLocal {
                Label("Already on this Mac at \(local.path) — “Open” opens that copy instead of cloning again.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existingLocal == nil ? "Clone" : "Open") {
                    if let local = existingLocal {
                        onRun(.openLocal(path: local.path, role: local.role == nil ? role : nil))
                        dismiss()
                    } else if let repo {
                        onRun(.cloneProject(repo: repo, role: role, vaultsDir: folder))
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(repo == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            role = hubleRoles.contains(model.state.role ?? "") ? model.state.role! : "cx"
            folder = model.state.effectiveVaultsDir
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            vaults = try await RemoteVaults.fetch()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
