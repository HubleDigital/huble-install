import Foundation

struct RemoteVault: Identifiable, Hashable {
    var id: String { nameWithOwner }
    let name: String
    let nameWithOwner: String
    let description: String?
    let pushedAt: String?
}

enum RemoteVaultsError: LocalizedError {
    case noGitHubCLI
    case notSignedIn
    case command(String)

    var errorDescription: String? {
        switch self {
        case .noGitHubCLI: return "GitHub CLI (gh) is not installed yet — use “Set up GitHub” in the main window first."
        case .notSignedIn: return "Not signed in to GitHub — use “Sign in to GitHub” in the main window first."
        case .command(let s): return s
        }
    }
}

enum RemoteVaults {
    static let org = "HubleDigital"
    static let topic = "guerilla-client-vault"

    /// Prefer the platform's `huble vault list --json`; fall back to the raw
    /// gh query from the contract when the verb does not exist yet.
    static func fetch() async throws -> [RemoteVault] {
        let huble = Shell.hubleHome + "/bin/huble"
        if FileManager.default.isExecutableFile(atPath: huble),
           let r = try? await Shell.run(huble, ["vault", "list", "--json"]),
           r.status == 0,
           let list = try? decode(r.stdout), !list.isEmpty {
            return list
        }
        guard let gh = Shell.gh() else { throw RemoteVaultsError.noGitHubCLI }
        let r = try await Shell.run(gh, [
            "repo", "list", org, "--topic", topic,
            "--json", "name,description,pushedAt", "--limit", "500",
        ])
        guard r.status == 0 else {
            if r.stderr.contains("gh auth login") { throw RemoteVaultsError.notSignedIn }
            let line = r.stderr.split(separator: "\n").last.map(String.init) ?? "gh repo list failed"
            throw RemoteVaultsError.command(line)
        }
        return try decode(r.stdout)
    }

    private struct Raw: Decodable {
        let name: String
        let nameWithOwner: String?
        let description: String?
        let pushedAt: String?
    }

    static func decode(_ json: String) throws -> [RemoteVault] {
        let raws = try JSONDecoder().decode([Raw].self, from: Data(json.utf8))
        return raws.map {
            RemoteVault(name: $0.name,
                        nameWithOwner: $0.nameWithOwner ?? "\(org)/\($0.name)",
                        description: $0.description.flatMap { $0.isEmpty ? nil : $0 },
                        pushedAt: $0.pushedAt)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
