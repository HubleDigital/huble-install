import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.installerPresent { installerBanner }
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
                    .disabled(!model.installerPresent)
                Button { model.showCloneProject = true } label: { Label("Clone project", systemImage: "icloud.and.arrow.down") }
                    .disabled(!model.installerPresent)
                Button { model.showOpenProject = true } label: { Label("Open project", systemImage: "folder") }
                    .disabled(!model.installerPresent)
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

    /// Platform on this Mac but no saved installer yet (set up before contract
    /// v1): the app fetches it in the background; until then the actions that
    /// spawn it are disabled with this reason.
    private var installerBanner: some View {
        HStack(spacing: 10) {
            if model.fetchingInstaller {
                ProgressView().controlSize(.small)
                Text("Installer not on this Mac yet — downloading…")
            } else if let err = model.installerFetchError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Installer not on this Mac yet — \(err)")
                    .lineLimit(2)
                Spacer()
                Button("Retry") { Task { await model.ensureInstaller() } }
            } else {
                ProgressView().controlSize(.small)
                Text("Installer not on this Mac yet — retrying…")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    /// "Update platform" appears only when `--check` reports an update; a
    /// blocked checkout shows why; offline shows a quiet note. Same rule as
    /// the Atlas plugin's Get Started page.
    private var footer: some View {
        HStack(spacing: 14) {
            Label(model.platformVersion.map { "Platform \($0)" } ?? "Platform not installed", systemImage: "cube")
            Label(model.githubLogin.map { "GitHub: \($0)" } ?? "GitHub: not signed in", systemImage: "person.crop.circle")
            Spacer()
            if !model.ghInstalled {
                Button("Set up GitHub") { model.run(.signInGitHub()) }.disabled(!model.installerPresent)
            } else if model.githubLogin == nil {
                Button("Sign in to GitHub") { model.run(.signInGitHub()) }.disabled(!model.installerPresent)
            }
            if !model.installerPresent {
                EmptyView()   // the banner above explains; no update check without the installer
            } else if model.checkingUpdates && model.updateCheck == nil {
                ProgressView().controlSize(.mini)
            } else if let c = model.updateCheck {
                if c.updateAvailable {
                    Button("Update platform") { model.run(.updatePlatform()) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.installerPresent)
                } else if c.blocked {
                    Label("Update blocked: local changes in ~/.huble/platform", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("Commit, stash or discard the changes in ~/.huble/platform, then the update becomes available.")
                } else if c.status == "current" {
                    Label("Up to date", systemImage: "checkmark.circle")
                } else if c.status == "missing" {
                    Button("Install platform") { model.run(.setup()) }
                } else {
                    Label("Couldn't check for updates", systemImage: "wifi.slash")
                        .help("No network, or GitHub unreachable. Checked again on the next launch.")
                }
            } else {
                Label("Couldn't check for updates", systemImage: "wifi.slash")
            }
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
    @State private var openVaultNotice = false
    @State private var pickRoleForUpdate = false

    /// What Remove will do to Obsidian, said before the user confirms.
    private var removeMessage: String {
        var s = "The folder moves to the Trash. The GitHub repository is not touched — you can clone the project again any time with “Clone project”."
        if vault.openInObsidian {
            s += "\n\nThis vault is open in Obsidian: Obsidian will close to forget it. Other open vaults reopen afterwards; anything running in them (an agent chat, an unsaved edit) is interrupted. If this is the only open vault, Obsidian stays closed."
        } else if Obsidian.isRunning {
            s += "\n\nObsidian stays open; it forgets this vault the next time it is closed."
        }
        return s
    }

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
            Button("Remove…") { confirmRemove = true }.disabled(!model.installerPresent)
            // Only when the vault's installed plugin differs from the one the
            // platform ships (what cx init installs) — equal means nothing to do.
            // Not a sync: it re-installs plugin/skills/commands, nothing else.
            if model.vaultNeedsUpdate(vault) {
                Button("Update Atlas in this vault") {
                    // Open in Obsidian: re-initialising would swap the plugin under
                    // the running app. The vault's own Get Started page updates it
                    // in place, so send the user there instead of running here.
                    // No recorded role: cx init needs one (and records it).
                    if vault.openInObsidian { openVaultNotice = true }
                    else if vault.role == nil { pickRoleForUpdate = true }
                    else { model.run(.updateVault(path: vault.path)) }
                }
                .confirmationDialog("Which role is this vault used for on this Mac?", isPresented: $pickRoleForUpdate, titleVisibility: .visible) {
                    ForEach(hubleRolesWithAll, id: \.self) { r in
                        Button(r == "all" ? "All (orchestrator / test machine)" : r.uppercased()) {
                            model.run(.updateVault(path: vault.path, role: r))
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("“\(vault.name)” has no recorded role yet. The role picks the Atlas tooling installed in it and is remembered for this vault.")
                }
                .disabled(!model.installerPresent)
                .help(vault.pluginVersion.map { "Atlas \($0) installed, platform ships \(model.platformPluginVersion ?? "?"). Re-installs the plugin, skills and commands — does not sync project files." } ?? "Atlas plugin not installed in this vault")
                .confirmationDialog("“\(vault.name)” is open in Obsidian", isPresented: $openVaultNotice, titleVisibility: .visible) {
                    Button("Open in Obsidian") { Obsidian.open(vaultPath: vault.path) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Update it from inside the vault: Obsidian → Get Started → Update platform. That updates Atlas in place without swapping files under the running app.")
                }
            }
            Button("Open in Obsidian") { Obsidian.open(vaultPath: vault.path) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Remove “\(vault.name)” from this Mac?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(vault.openInObsidian ? "Close Obsidian and move to Trash" : "Move to Trash", role: .destructive) {
                model.run(.removeVault(path: vault.path))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
    }
}
