// devdeck-hook <agent>
//
// Installed as an agent hook (Claude Code, Codex). Reads the hook's JSON from stdin and
// forwards device-related tool calls and session ends to DevDeck's socket. It always
// exits 0 and prints nothing, so an agent is never blocked or slowed down, and nothing
// happens when DevDeck isn't running.
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

let agent = CommandLine.arguments.dropFirst().first ?? "agent"
let input = FileHandle.standardInput.readDataToEndOfFile()
guard var event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

/// Cheap filter so DevDeck only hears about calls that can touch a device.
func isRelevant(_ event: [String: Any]) -> Bool {
    switch event["hook_event_name"] as? String {
    case "SessionEnd":
        return true
    case "PreToolUse":
        let tool = event["tool_name"] as? String ?? ""
        if tool.hasPrefix("mcp__argent__") { return true }
        guard tool == "Bash", let command = (event["tool_input"] as? [String: Any])?["command"] as? String
        else { return false }
        return command.range(of: #"\b(simctl|adb|emulator)\b"#, options: .regularExpression) != nil
    default:
        return false
    }
}

guard isRelevant(event) else { exit(0) }
event["agent"] = agent
if ProcessInfo.processInfo.environment["T3CODE_CLI_PATH"] != nil { event["host"] = "T3 Code" }
event.removeValue(forKey: "transcript_path")
guard var line = try? JSONSerialization.data(withJSONObject: event) else { exit(0) }
line.append(0x0A)

// Keep in sync with BrokerServer.socketURL.
let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DevDeck/broker.sock").path

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(path.utf8) + [0]
guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if connected == 0 {
    line.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if written <= 0 { break }
            offset += written
        }
    }
}
close(fd)
exit(0)
