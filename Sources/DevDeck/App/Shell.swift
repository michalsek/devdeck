import Foundation

/// Runs command-line tools off the main thread.
///
/// Apps started from Finder get a minimal PATH, so tools are looked up in the
/// usual Homebrew and SDK locations too.
enum Shell {
    struct Result: Sendable {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    static let path = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        androidSDK.appendingPathComponent("platform-tools").path,
        androidSDK.appendingPathComponent("emulator").path,
    ].joined(separator: ":")

    static var androidSDK: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk")
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }

    /// Runs `tool` (a name looked up on `path`, or an absolute path) and waits for it.
    /// Output is stdout followed by stderr. A tool that is not installed returns status 127.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 20) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runSync(tool, args, timeout: timeout))
            }
        }
    }

    static func runSync(_ tool: String, _ args: [String], timeout: TimeInterval = 20) -> Result {
        guard let executable = resolve(tool) else {
            return Result(status: 127, output: "\(tool) not found")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Read both pipes before waiting so a chatty tool can't block on a full pipe.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        process.waitUntilExit()
        deadline.cancel()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self) + String(decoding: errData, as: UTF8.self))
    }

    /// Starts a long-running tool (an emulator, say) without waiting for it.
    static func spawn(_ tool: String, _ args: [String]) -> Bool {
        guard let executable = resolve(tool) else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    static func resolve(_ tool: String) -> URL? {
        if tool.hasPrefix("/") { return URL(fileURLWithPath: tool) }
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return xcodeTools.contains(tool) ? xcodeTool(tool) : nil
    }

    /// Xcode's tools aren't on PATH. `xcrun --find` locates each once, so a call starts the
    /// tool itself rather than xcrun and then the tool.
    private static let xcodeTools: Set<String> = ["simctl", "devicectl"]
    private static let xcodeLock = NSLock()
    nonisolated(unsafe) private static var xcodePaths: [String: URL] = [:]

    private static func xcodeTool(_ tool: String) -> URL? {
        xcodeLock.lock()
        defer { xcodeLock.unlock() }
        if let url = xcodePaths[tool], FileManager.default.isExecutableFile(atPath: url.path) { return url }
        let found = runSync("/usr/bin/xcrun", ["--find", tool])
        guard found.ok, let line = found.output.split(whereSeparator: \.isNewline).first else { return nil }
        let url = URL(fileURLWithPath: String(line))
        xcodePaths[tool] = url
        return url
    }
}
