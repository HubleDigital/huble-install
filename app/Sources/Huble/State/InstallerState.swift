import Foundation

/// `~/.huble/installer.json` — defaults the installer offers (see contract).
/// Every key may be missing on machines installed before contract v1. Read-only.
struct InstallerState {
    var installerVersion: String?
    var role: String?
    var vaultsDir: String?
    var lastVault: String?

    static var path: String { Shell.hubleHome + "/installer.json" }

    static func load() -> InstallerState {
        var s = InstallerState()
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return s }
        s.installerVersion = obj["installerVersion"] as? String
        s.role = obj["role"] as? String
        s.vaultsDir = obj["vaultsDir"] as? String
        s.lastVault = obj["lastVault"] as? String
        return s
    }

    /// Where a new vault goes when nothing is stored yet.
    var effectiveVaultsDir: String {
        vaultsDir ?? (Shell.home + "/Documents/Huble")
    }
}
