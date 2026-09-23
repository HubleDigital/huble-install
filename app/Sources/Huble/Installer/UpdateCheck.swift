import Foundation

/// Result of `install.sh --check` (contract feature `check`): read-only,
/// never pulls or installs. Drives whether "Update platform" is shown at all.
struct UpdateCheck: Decodable, Equatable {
    struct Platform: Decodable, Equatable {
        let state: String          // "ok" | "missing"
        let behind: Int?
        let ahead: Int?
        let dirty: Bool
        let local: String
        let remote: String
        let branch: String
    }
    struct Installer: Decodable, Equatable {
        let status: String         // "current" | "available" | "unknown"
        let local: String
        let remote: String
    }
    let status: String             // "current" | "available" | "blocked" | "missing" | "unknown"
    let platform: Platform
    let installer: Installer

    var updateAvailable: Bool { status == "available" || installer.status == "available" }
    var blocked: Bool { status == "blocked" }

    static func run() async -> UpdateCheck? {
        guard Bootstrap.installerExists else { return nil }
        let r = try? await Shell.run("/bin/bash", [Shell.installerPath, "--check"], extraEnv: ["HUBLE_OUTPUT": "json"])
        guard let r, r.status == 0 else { return nil }
        for line in r.stdout.split(separator: "\n") {
            if let c = try? JSONDecoder().decode(UpdateCheck.self, from: Data(line.utf8)) { return c }
        }
        return nil
    }
}
