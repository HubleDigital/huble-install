import AppKit
import SwiftUI

let hubleRoles = ["cx", "copy", "seo", "design", "dev"]
/// Roles offered when a vault has no recorded one: `all` is a real machine
/// role (orchestrator / test machines), just not a default in the pickers.
let hubleRolesWithAll = hubleRoles + ["all"]

enum Obsidian {
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").isEmpty
    }

    /// `obsidian://open?path=<encoded>` for a vault Obsidian already knows.
    static func open(vaultPath: String) {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let enc = vaultPath.addingPercentEncoding(withAllowedCharacters: allowed) ?? vaultPath
        if let url = URL(string: "obsidian://open?path=\(enc)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum FolderPicker {
    static func choose(startingAt path: String, message: String = "Folder that will contain the client vault") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = URL(fileURLWithPath: path)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct RoleBadge: View {
    let role: String?
    var body: some View {
        Text((role ?? "?").uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(role == nil ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.18))
            .clipShape(Capsule())
    }
}

struct FolderField: View {
    @Binding var folder: String
    var body: some View {
        HStack {
            Text(folder)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Choose…") {
                if let p = FolderPicker.choose(startingAt: folder) { folder = p }
            }
        }
    }
}
