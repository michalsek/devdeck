// devdeck-hook <agent>
//
// Installed as an agent hook (Claude Code, Codex). Reads the hook's JSON from stdin and
// forwards device-related tool calls, turn ends, session ends and the events that play
// agent sounds to DevDeck's socket (see `HookProtocol`).
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
import DevDeckProtocol
import Foundation

signal(SIGPIPE, SIG_IGN)

let environment = ProcessInfo.processInfo.environment
/// DEVDECK_HOOK_MAX_WAIT shortens the wait, for testing.
let maxWait = environment["DEVDECK_HOOK_MAX_WAIT"].flatMap(Double.init) ?? HookProtocol.maxWait

let agent = CommandLine.arguments.dropFirst().first ?? "agent"
let input = FileHandle.standardInput.readDataToEndOfFile()
guard var event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      HookProtocol.isRelevant(event)
else { exit(0) }
let eventName = event["hook_event_name"] as? String ?? ""
let isResult = eventName == "PostToolUse" || eventName == "PostToolUseFailure"
let deviceInUse = isResult ? HookProtocol.deviceInUseOutput(event) : nil
// Advice only comes back about DEVICE_IN_USE; other results are just reported.
let waits = eventName == "PreToolUse" || deviceInUse != nil

if isResult {
    // Only the error, or the end of a device command's output, goes to DevDeck.
    event[HookProtocol.Field.toolOutput] = deviceInUse ?? HookProtocol.resultOutput(event)
    event.removeValue(forKey: "tool_response")
    event.removeValue(forKey: "error")
}
event[HookProtocol.Field.agent] = agent
event[HookProtocol.Field.maxWait] = maxWait
event[HookProtocol.Field.agentPID] = Int(getppid())
if eventName == "PreToolUse" { event[HookProtocol.Field.path] = environment["PATH"] }
if environment["T3CODE_CLI_PATH"] != nil { event[HookProtocol.Field.host] = "T3 Code" }
event.removeValue(forKey: "transcript_path")
event.removeValue(forKey: "prompt")
guard var line = try? JSONSerialization.data(withJSONObject: event) else { exit(0) }
line.append(0x0A)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0, var address = HookProtocol.address(HookProtocol.socketPath()) else { exit(0) }
var sendTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0, HookProtocol.writeAll(fd, line), waits else {
    close(fd)
    exit(0)
}

let replyTimeout = isResult ? HookProtocol.adviceTimeout : maxWait + HookProtocol.replyGrace
var receiveTimeout = timeval(tv_sec: Int(replyTimeout), tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
var reply = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while !reply.contains(0x0A) {
    let count = read(fd, &buffer, buffer.count)
    if count <= 0 { break }
    reply.append(buffer, count: count)
}
close(fd)

let answer = try? JSONDecoder().decode(HookReply.self, from: reply.split(separator: 0x0A).first ?? Data())
if isResult {
    if let context = answer?.context,
       let output = try? JSONSerialization.data(withJSONObject: [
           "hookSpecificOutput": ["hookEventName": eventName, "additionalContext": context],
       ]) {
        FileHandle.standardOutput.write(output)
    }
    exit(0)
}
if answer?.decision == .deny {
    FileHandle.standardError.write(Data((answer?.reason ?? "DevDeck: the user is using this device.").utf8))
    exit(2)
}
exit(0)
