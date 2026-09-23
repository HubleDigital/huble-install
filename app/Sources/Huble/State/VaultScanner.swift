import Foundation

struct LocalVault: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let role: String?
    /// `owner/name` of the git origin, lowercased — the contract's rule for
    /// matching a local vault to a GitHub repo. nil without a git origin.
    let origin: String?
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
            vaults.append(LocalVault(name: displayName(p), path: p, role: role(of: p), origin: origin(of: p)))
        }

        if let dir = state.vaultsDir,
           let entries = try? fm.contentsOfDirectory(atPath: dir) {
            for e in entries.sorted() where !e.hasPrefix(".") {
                add((dir as NSString).appendingPathComponent(e))
            }
        }
        // Obsidian's own vault list is the durable source: a vault that lives
        // outside vaultsDir stays listed here for as long as Obsidian knows it,
        // instead of vanishing the moment lastVault moves on.
        for p in obsidianVaultPaths() { add(p) }
        if let last = state.lastVault { add(last) }
        return vaults
    }

    static func obsidianVaultPaths() -> [String] {
        let cfg = Shell.home + "/Library/Application Support/obsidian/obsidian.json"
        guard let data = FileManager.default.contents(atPath: cfg),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = obj["vaults"] as? [String: Any]
        else { return [] }
        return vaults.values
            .compactMap { ($0 as? [String: Any])?["path"] as? String }
            .sorted()
    }

    static func isVault(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.fileExists(atPath: path + "/.huble") || fm.fileExists(atPath: path + "/project-config.json")
    }

    /// Parses `.git/config` for the origin URL and reduces it to `owner/name`
    /// (lowercased); handles `https://github.com/o/n(.git)` and
    /// `git@github.com:o/n(.git)`. No git subprocess — this runs on every refresh.
    static func origin(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/.git/config"),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"; continue }
            guard inOrigin, line.hasPrefix("url") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            return normalizeRepo(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func normalizeRepo(_ url: String) -> String? {
        var s = url
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let r = s.range(of: "github.com/") { s = String(s[r.upperBound...]) }
        else if let r = s.range(of: "github.com:") { s = String(s[r.upperBound...]) }
        let parts = s.split(separator: "/").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])".lowercased()
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
