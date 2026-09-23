import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.vaults.isEmpty {
                ContentUnavailableView {
                    Label("No projects on this Mac", systemImage: "folder")
                } description: {
                    Text("Create a new project, clone a client vault from GitHub, or open a vault folder already on this Mac.")
                } actions: {
                    Button("New project") { model.showNewProject = true }
                    Button("Clone project") { model.showCloneProject = true }
                    Button("Open project") { model.showOpenProject = true }
                }
            } else {
                List(model.vaults) { vault in
                    VaultRow(vault: vault)
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showNewProject = true } label: { Label("New project", systemImage: "plus") }
                Button { model.showCloneProject = true } label: { Label("Clone project", systemImage: "icloud.and.arrow.down") }
                Button { model.showOpenProject = true } label: { Label("Open project", systemImage: "folder") }
            }
        }
        .sheet(isPresented: $model.showNewProject) {
            NewProjectSheet { model.run($0) }
        }
        .sheet(isPresented: $model.showCloneProject) {
            CloneProjectSheet { model.run($0) }
        }
        .sheet(isPresented: $model.showOpenProject) {
            OpenProjectSheet { model.run($0) }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label(model.platformVersion.map { "Platform \($0)" } ?? "Platform not installed", systemImage: "cube")
            Label(model.githubLogin.map { "GitHub: \($0)" } ?? "GitHub: not signed in", systemImage: "person.crop.circle")
            Spacer()
            Button("Update platform") { model.run(.updatePlatform()) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct VaultRow: View {
    @Environment(AppModel.self) private var model
    let vault: LocalVault
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(vault.name).font(.headline)
                    RoleBadge(role: vault.role)
                }
                Text(vault.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Remove…") { confirmRemove = true }
            Button("Update vault") { model.run(.updateVault(path: vault.path)) }
            Button("Open in Obsidian") { Obsidian.open(vaultPath: vault.path) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Remove “\(vault.name)” from this Mac?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.run(.removeVault(path: vault.path)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder moves to the Trash. The GitHub repository is not touched — you can clone the project again any time with “Clone project”.")
        }
    }
}
