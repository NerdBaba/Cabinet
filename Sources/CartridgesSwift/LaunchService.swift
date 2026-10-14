import AppKit
import Foundation

@MainActor
enum LaunchService {
    static func launch(_ game: Game) async throws {
        switch game.launchType {
        case .app:
            try await openApp(game.launchTarget)
        case .heroic:
            guard let url = URL(string: game.launchTarget), NSWorkspace.shared.open(url) else {
                throw CartridgesError.message("Could not open the Heroic launch link. Check that Heroic is installed.")
            }
        case .steam:
            guard let url = URL(string: game.launchTarget), url.scheme == "steam", NSWorkspace.shared.open(url) else {
                throw CartridgesError.message("Could not open the Steam launch link. Check that Steam is installed.")
            }
        case .shell:
            let trimmed = game.launchTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            let appPath = (trimmed as NSString).expandingTildeInPath
            if appPath.hasSuffix(".app"), FileManager.default.fileExists(atPath: appPath) {
                try await openApp(appPath)
                return
            }
            let parts = FileManager.default.isExecutableFile(atPath: appPath) ? [appPath] : try arguments(trimmed)
            guard let command = parts.first else { throw CartridgesError.message("Empty launch command") }
            let process = Process()
            process.executableURL = try executable(command, workingDir: game.workingDir)
            process.arguments = Array(parts.dropFirst())
            if let directory = game.workingDir, !directory.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // A game is a long-running process; record a successful start without waiting for its exit.
            // The brief grace period still catches an executable that rejects its arguments immediately.
            try await Task.sleep(nanoseconds: 200_000_000)
            if !process.isRunning, process.terminationStatus != 0 {
                throw CartridgesError.message("Command exited with status \(process.terminationStatus)")
            }
        }
    }
    private static func openApp(_ path: String) async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CartridgesError.message("Application no longer exists at \(path)") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if app != nil { continuation.resume() }
                else { continuation.resume(throwing: CartridgesError.message("macOS could not launch the application")) }
            }
        }
    }
    static func executable(_ command: String, workingDir: String? = nil) throws -> URL {
        let manager = FileManager.default
        let command = (command as NSString).expandingTildeInPath
        if command.contains("/") {
            let file: URL
            if !command.hasPrefix("/"), let workingDir, !workingDir.isEmpty {
                file = URL(fileURLWithPath: (workingDir as NSString).expandingTildeInPath).appendingPathComponent(command).standardizedFileURL
            } else { file = URL(fileURLWithPath: command) }
            guard manager.isExecutableFile(atPath: file.path) else { throw CartridgesError.message("Executable not found: \(command)") }
            return file
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(command)
            if manager.isExecutableFile(atPath: url.path) { return url }
        }
        throw CartridgesError.message("Command not found: \(command)")
    }
    /// Parse argv only: supports quoted paths and escaped spaces without evaluating a shell.
    static func arguments(_ command: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in command {
            if escaped { current.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let existingQuote = quote {
                if character == existingQuote { quote = nil } else { current.append(character) }
                started = true
            } else if character == "\"" || character == "'" {
                quote = character; started = true
            } else if character.isWhitespace {
                if started { result.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        guard quote == nil, !escaped else { throw CartridgesError.message("Launch command has an unfinished quote or escape") }
        if started { result.append(current) }
        return result
    }
    static func afterLaunch(_ action: AfterLaunchAction) {
        guard action != .stay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            switch action {
            case .stay: break
            case .hide: NSApp.hide(nil)
            case .minimize: NSApp.windows.forEach { $0.miniaturize(nil) }
            case .quit: NSApp.terminate(nil)
            }
        }
    }
}
