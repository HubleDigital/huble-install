import AppKit
import Foundation
import Observation

/// One run of `~/.huble/install.sh`. Streams the contract's JSON events into
/// UI state; the raw stderr is kept only as a log for humans.
@MainActor
@Observable
final class InstallerRun: Identifiable {
    enum StepState { case running, ok, warning, failed }
    enum NoteKind { case ok, note, warn, error }
    struct Note: Identifiable {
        let id = UUID()
        let kind: NoteKind
        let text: String
    }
    struct Step: Identifiable {
        let id = UUID()
        var title: String
        var state: StepState
        var notes: [Note] = []
    }
    enum Status: Equatable {
        case running, succeeded, failed(String), cancelled
    }

    let id = UUID()
    let action: InstallerAction

    private(set) var steps: [Step] = []
    private(set) var status: Status = .running
    private(set) var log = ""          // raw stderr from the installer and its subcommands
    private(set) var eventLog = ""     // every stdout line, decoded or not
    private(set) var ghAuthCode: String?
    private(set) var ghAuthURL: String?
    private(set) var vaultPath: String?
    private(set) var installerVersion: String?
    private(set) var platformUpdated: Bool?
    private(set) var failReason: String?   // the contract's machine-readable `reason` on a fail event

    private var process: Process?
    private var stdoutBuffer = Data()
    private var sawContract = false
    private var cancelRequested = false
    private var openedAuthURL = false

    static var installerPath: String { Shell.installerPath }

    init(action: InstallerAction) {
        self.action = action
    }

    var isRunning: Bool { status == .running }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.installerPath] + action.flags
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.clientPATH
        env["HOME"] = Shell.home
        env["HUBLE_OUTPUT"] = "json"
        env["HUBLE_NONINTERACTIVE"] = "1"
        for (k, v) in action.env { env[k] = v }
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: Shell.home)

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        process = p

        do {
            try p.run()
        } catch {
            finish(status: .failed("Could not start the installer: \(error.localizedDescription)"))
            return
        }

        // Dedicated reader threads, each forwarding chunks to the main actor in
        // order; termination is only reported after BOTH streams hit EOF, so the
        // last events are never lost behind the exit notification.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fh = out.fileHandleForReading
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.consumeStdout(chunk) } }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fh = err.fileHandleForReading
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                let text = String(decoding: chunk, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.log += text } }
            }
            group.leave()
        }
        group.notify(queue: .global()) { [weak self] in
            p.waitUntilExit()
            let code = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processExited(code: code) } }
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        process?.terminate()
    }

    // MARK: - stdout → events

    private func consumeStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            eventLog += line + "\n"
            if let ev = try? JSONDecoder().decode(InstallerEvent.self, from: lineData) {
                handle(ev)
            }
        }
    }

    private func handle(_ ev: InstallerEvent) {
        if !sawContract {
            guard ev.event == "contract", ev.contract == "v1" else {
                cancelRequested = true
                process?.terminate()
                finish(status: .failed("This installer speaks an unknown contract (\(ev.contract ?? ev.event)). Update the Huble app."))
                return
            }
            sawContract = true
            installerVersion = ev.version
            return
        }
        guard isRunning else { return }
        let msg = ev.message ?? ""
        switch ev.event {
        case "step":
            closeCurrentStep(as: .ok)
            steps.append(Step(title: msg, state: .running))
        case "ok":
            appendNote(.ok, msg)
        case "note":
            appendNote(.note, msg)
        case "warn":
            appendNote(.warn, msg)
            markCurrent(.warning)
        case "error":
            appendNote(.error, msg)
            markCurrent(.warning)
        case "gh_auth":
            ghAuthCode = ev.code
            ghAuthURL = ev.url
            if !openedAuthURL, let s = ev.url, let url = URL(string: s) {
                openedAuthURL = true
                NSWorkspace.shared.open(url)
            }
        case "vault":
            vaultPath = ev.path
        case "fail":
            failReason = ev.reason
            closeCurrentStep(as: .failed)
            finish(status: .failed(msg.isEmpty ? "The installer failed." : msg))
        case "done":
            vaultPath = (ev.vault?.isEmpty == false) ? ev.vault : vaultPath
            platformUpdated = ev.platformUpdated
            closeCurrentStep(as: .ok)
            finish(status: .succeeded)
        default:
            break
        }
    }

    private func appendNote(_ kind: NoteKind, _ text: String) {
        guard !text.isEmpty else { return }
        if steps.isEmpty { steps.append(Step(title: action.title, state: .running)) }
        steps[steps.count - 1].notes.append(Note(kind: kind, text: text))
    }

    private func markCurrent(_ state: StepState) {
        guard let i = steps.indices.last, steps[i].state == .running else { return }
        steps[i].state = state
    }

    /// A running step becomes `as`; a step that already collected a warning
    /// keeps the warning unless the outcome is a failure.
    private func closeCurrentStep(as outcome: StepState) {
        guard let i = steps.indices.last else { return }
        switch (steps[i].state, outcome) {
        case (.running, _): steps[i].state = outcome
        case (.warning, .failed): steps[i].state = .failed
        default: break
        }
    }

    private func processExited(code: Int32) {
        process = nil
        guard isRunning else { return }
        if cancelRequested {
            closeCurrentStep(as: .failed)
            finish(status: .cancelled)
        } else {
            closeCurrentStep(as: .failed)
            let why = sawContract
                ? "The installer exited with status \(code) without reporting why. See the log."
                : "No installer contract received (exit \(code)). Is ~/.huble/install.sh a contract v1 installer?"
            finish(status: .failed(why))
        }
    }

    private func finish(status: Status) {
        ghAuthCode = nil
        ghAuthURL = nil
        self.status = status
    }
}
