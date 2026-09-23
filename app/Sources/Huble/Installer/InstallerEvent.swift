import Foundation

/// One NDJSON line from the installer's stdout (HUBLE_OUTPUT=json).
/// Field names follow docs/installer-contract.md; unknown events are kept in
/// the log and otherwise ignored so a newer installer does not break the app.
struct InstallerEvent: Decodable {
    let event: String
    var message: String?
    var contract: String?
    var version: String?
    var code: String?
    var url: String?
    var path: String?
    var vault: String?
    var platformUpdated: Bool?
}

/// What the app asks the installer to do: only env + flags, never a shell string.
struct InstallerAction {
    var title: String
    var env: [String: String]
    var flags: [String] = []

    static func setup() -> InstallerAction {
        InstallerAction(title: "Setting up this Mac", env: ["HUBLE_VAULT_MODE": "skip", "HUBLE_VAULT_REINIT": "no", "HUBLE_NO_OPEN": "1"])
    }

    static func updatePlatform() -> InstallerAction {
        InstallerAction(title: "Updating the platform", env: ["HUBLE_VAULT_MODE": "skip", "HUBLE_VAULT_REINIT": "no", "HUBLE_NO_OPEN": "1"])
    }

    static func updateVault(path: String) -> InstallerAction {
        InstallerAction(title: "Updating vault", env: ["HUBLE_VAULT_MODE": "skip", "HUBLE_VAULT_REINIT": path, "HUBLE_NO_OPEN": "1"])
    }

    static func newProject(client: String, role: String, vaultsDir: String) -> InstallerAction {
        // HUBLE_NO_OPEN stays unset: the installer registers and opens the vault in Obsidian.
        InstallerAction(title: "Creating project “\(client)”", env: [
            "HUBLE_VAULT_MODE": "new", "HUBLE_CLIENT_NAME": client, "HUBLE_ROLE": role, "HUBLE_VAULTS_DIR": vaultsDir,
        ])
    }

    static func cloneProject(repo: String, role: String, vaultsDir: String) -> InstallerAction {
        InstallerAction(title: "Opening project \(repo)", env: [
            "HUBLE_VAULT_MODE": "clone", "HUBLE_VAULT_REPO": repo, "HUBLE_ROLE": role, "HUBLE_VAULTS_DIR": vaultsDir,
        ])
    }
}
