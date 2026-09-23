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
        if let r, r.status == 0 {
            for line in r.stdout.split(separator: "\n") {
                if let c = try? JSONDecoder().decode(UpdateCheck.self, from: Data(line.utf8)) { return c }
            }
        }
        // A saved copy from before --check existed answers "Unknown flag" —
        // that IS an installer update waiting (the next run refreshes the copy),
        // not a failed check. Confirm via --contract's feature list.
        if let c = try? await Shell.run("/bin/bash", [Shell.installerPath, "--contract"], extraEnv: ["HUBLE_OUTPUT": "json"]),
           c.status == 0,
           let line = c.stdout.split(separator: "\n").first,
           let ev = try? JSONDecoder().decode(ContractEvent.self, from: Data(line.utf8)),
           !(ev.features ?? []).contains("check") {
            return UpdateCheck(
                status: "unknown",
                platform: Platform(state: "ok", behind: nil, ahead: nil, dirty: false, local: "", remote: "", branch: ""),
                installer: Installer(status: "available", local: ev.version ?? "?", remote: "newer"))
        }
        return nil
    }

    private struct ContractEvent: Decodable {
        let contract: String?
        let version: String?
        let features: [String]?
    }
}
