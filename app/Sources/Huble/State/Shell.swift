import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let hubleHome = home + "/.huble"

    /// The PATH the contract asks clients to pass. The installer extends it
    /// itself (node, npm-global, Homebrew) — the app never has to.
    static let clientPATH = "/usr/bin:/bin:/usr/sbin:/sbin:\(hubleHome)/bin"
    static let installerPath = hubleHome + "/install.sh"

    /// Run a command to completion and capture both streams. Used for the small
    /// read-only queries (gh, git, huble vault list); installer runs go through
    /// InstallerRun, which streams.
    static func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = clientPATH + ":/opt/homebrew/bin:/usr/local/bin"
                env["HOME"] = home
                p.environment = env
                p.currentDirectoryURL = URL(fileURLWithPath: home)
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                // Drain stderr on its own queue so a chatty command cannot
                // deadlock on a full pipe while we read stdout.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: CommandResult(
                    status: p.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    /// First existing executable among the candidates, then a PATH lookup.
    static func find(_ name: String, candidates: [String]) -> String? {
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        for dir in (clientPATH + ":/opt/homebrew/bin:/usr/local/bin").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func gh() -> String? {
        find("gh", candidates: ["\(hubleHome)/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
    }
}
