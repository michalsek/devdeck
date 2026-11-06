// devdeck-hook <agent>
//
// Installed as an agent hook (Claude Code, Codex). Reads the hook's JSON from stdin and
// forwards device-related tool calls, turn ends and session ends to DevDeck's socket.
//
// For a tool call DevDeck may hold the answer back while the user has the device; the
// hook then waits (up to `maxWait`). If DevDeck refuses the call, the hook prints the
// reason for the agent and exits 2, which blocks the call. Anything else (DevDeck not
// running, crashed, slow, or an unrelated call) exits 0 and the call goes ahead.
//
// After a shell command agent-device turned away with DEVICE_IN_USE, DevDeck may answer
// with what it knows about the device's holder; the hook hands that to the agent as
// additional context.
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

/// Below the hook timeout DevDeck installs (600 s), so DevDeck can still answer in time.
/// DEVDECK_HOOK_MAX_WAIT shortens it, for testing.
let maxWait: Double = ProcessInfo.processInfo.environment["DEVDECK_HOOK_MAX_WAIT"].flatMap(Double.init) ?? 540

let agent = CommandLine.arguments.dropFirst().first ?? "agent"
let input = FileHandle.standardInput.readDataToEndOfFile()
guard var event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
let eventName = event["hook_event_name"] as? String ?? ""

let isResult = eventName == "PostToolUse" || eventName == "PostToolUseFailure"

/// All the text in a tool's result: Claude Code's `{stdout, stderr}`, Codex's output, or
/// the error of a failed call.
func text(of value: Any?) -> String {
    switch value {
    case let string as String: return string
    case let object as [String: Any]: return object.keys.sorted().map { text(of: object[$0]) }.joined(separator: "\n")
    case let list as [Any]: return list.map { text(of: $0) }.joined(separator: "\n")
    default: return ""
    }
}

/// For a finished shell command: the part of its output around a DEVICE_IN_USE error.
func deviceInUseOutput(_ event: [String: Any]) -> String? {
    guard event["tool_name"] as? String == "Bash" else { return nil }
    let output = text(of: event["tool_response"]) + "\n" + text(of: event["error"])
    guard let found = output.range(of: "DEVICE_IN_USE") else { return nil }
    let start = output.index(found.lowerBound, offsetBy: -500, limitedBy: output.startIndex) ?? output.startIndex
    let end = output.index(found.upperBound, offsetBy: 2000, limitedBy: output.endIndex) ?? output.endIndex
    return String(output[start..<end])
}

/// Cheap filter so DevDeck only hears about calls that can touch a device.
func isRelevant(_ event: [String: Any]) -> Bool {
    switch eventName {
    case "SessionEnd", "Stop":
        return true
    case "PostToolUse", "PostToolUseFailure":
        return deviceInUseOutput(event) != nil
    case "PreToolUse":
        let tool = event["tool_name"] as? String ?? ""
        if tool.hasPrefix("mcp__argent__") { return true }
        guard tool == "Bash", let command = (event["tool_input"] as? [String: Any])?["command"] as? String
        else { return false }
        // Devices (agent-device is behind T3 Code's device tools), and heavy work DevDeck
        // may make wait for room (builds, dev servers).
        return command.range(
            of: #"\b(simctl|adb|emulator|agent-device|xcodebuild|gradlew|gradle|expo|react-native|eas|npm|yarn|pnpm|bun|vite|next|nuxt|astro|remix|storybook|start-storybook|metro)\b"#,
            options: .regularExpression) != nil
    default:
        return false
    }
}

guard isRelevant(event) else { exit(0) }
let waits = eventName == "PreToolUse" || isResult
if isResult {
    // Only the error goes to DevDeck, not the whole output.
    event["tool_output"] = deviceInUseOutput(event)
    event.removeValue(forKey: "tool_response")
    event.removeValue(forKey: "error")
}
event["agent"] = agent
event["wait"] = waits
event["max_wait"] = maxWait
if ProcessInfo.processInfo.environment["T3CODE_CLI_PATH"] != nil { event["host"] = "T3 Code" }
event.removeValue(forKey: "transcript_path")
guard var line = try? JSONSerialization.data(withJSONObject: event) else { exit(0) }
line.append(0x0A)

// Keep in sync with BrokerServer.socketURL. DEVDECK_SOCKET points the helper elsewhere, for testing.
let path = ProcessInfo.processInfo.environment["DEVDECK_SOCKET"] ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DevDeck/broker.sock").path

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var sendTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

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
guard connected == 0 else { exit(0) }

let sent = line.withUnsafeBytes { buffer -> Bool in
    var offset = 0
    while offset < buffer.count {
        let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if written <= 0 { return false }
        offset += written
    }
    return true
}
guard sent, waits else {
    close(fd)
    exit(0)
}

// Wait for DevDeck's answer, a little longer than DevDeck itself waits. Advice after a
// command comes at once, or not at all.
var receiveTimeout = timeval(tv_sec: isResult ? 5 : Int(maxWait) + 15, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
var reply = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while !reply.contains(0x0A) {
    let count = read(fd, &buffer, buffer.count)
    if count <= 0 { break }
    reply.append(buffer, count: count)
}
close(fd)

let answer = (try? JSONSerialization.jsonObject(with: reply.split(separator: 0x0A).first ?? Data())) as? [String: Any]
if isResult {
    if let context = answer?["context"] as? String,
       let output = try? JSONSerialization.data(withJSONObject: [
           "hookSpecificOutput": ["hookEventName": eventName, "additionalContext": context],
       ]) {
        FileHandle.standardOutput.write(output)
    }
    exit(0)
}
if answer?["decision"] as? String == "deny" {
    FileHandle.standardError.write(Data(((answer?["reason"] as? String) ?? "DevDeck: the user is using this device.").utf8))
    exit(2)
}
exit(0)
