import Foundation

struct LocalVault: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let role: String?
}

enum VaultScanner {
    static func scan(_ state: InstallerState) -> [LocalVault] {
        let fm = FileManager.default
        var seen = Set<String>()
        var vaults: [LocalVault] = []

        func add(_ path: String) {
            let p = (path as NSString).standardizingPath
            guard !seen.contains(p), isVault(p) else { return }
            seen.insert(p)
            vaults.append(LocalVault(name: displayName(p), path: p, role: role(of: p)))
        }

        if let dir = state.vaultsDir,
           let entries = try? fm.contentsOfDirectory(atPath: dir) {
            for e in entries.sorted() where !e.hasPrefix(".") {
                add((dir as NSString).appendingPathComponent(e))
            }
        }
        if let last = state.lastVault { add(last) }
        return vaults
    }

    static func isVault(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.fileExists(atPath: path + "/.huble") || fm.fileExists(atPath: path + "/project-config.json")
    }

    static func role(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/.huble/machine.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["role"] as? String
    }

    /// Client name from project-config.json when an obvious key exists,
    /// otherwise the folder name.
    static func displayName(_ path: String) -> String {
        let folder = (path as NSString).lastPathComponent
        guard let data = FileManager.default.contents(atPath: path + "/project-config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return folder }
        for key in ["clientName", "client", "name"] {
            if let s = obj[key] as? String, !s.isEmpty { return s }
            if let nested = obj[key] as? [String: Any], let s = nested["name"] as? String, !s.isEmpty { return s }
        }
        return folder
    }
}
