import Foundation

/// First run on a Mac: `~/.huble/install.sh` does not exist yet, so the app
/// fetches it once from the public bootstrap URL. Every later run uses the
/// local copy, which the installer refreshes itself.
enum Bootstrap {
    static let defaultURL = "https://raw.githubusercontent.com/HubleDigital/huble-install/main/install.sh"

    static var installerURL: URL {
        let s = ProcessInfo.processInfo.environment["HUBLE_INSTALL_URL"] ?? defaultURL
        return URL(string: s) ?? URL(string: defaultURL)!
    }

    static var installerExists: Bool {
        FileManager.default.isReadableFile(atPath: Shell.installerPath)
    }

    /// The platform checkout with its CLI — the real "this Mac is set up" signal.
    static var platformExists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Shell.hubleHome + "/platform/.git")
            && fm.fileExists(atPath: Shell.hubleHome + "/platform/huble-pipeline/bin/huble")
    }

    enum BootstrapError: LocalizedError {
        case badResponse(Int)
        case notAScript

        var errorDescription: String? {
            switch self {
            case .badResponse(let c): return "Download failed (HTTP \(c)). Check your network and try again."
            case .notAScript: return "The downloaded file is not the installer script."
            }
        }
    }

    static func downloadInstaller() async throws {
        let (data, response) = try await URLSession.shared.data(from: installerURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw BootstrapError.badResponse(http.statusCode)
        }
        guard data.count > 100, data.starts(with: Array("#!".utf8)) else { throw BootstrapError.notAScript }
        let fm = FileManager.default
        try fm.createDirectory(atPath: Shell.hubleHome, withIntermediateDirectories: true)
        let path = Shell.installerPath
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
