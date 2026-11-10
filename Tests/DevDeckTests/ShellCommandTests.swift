import DevDeckProtocol
import XCTest

final class ShellCommandTests: XCTestCase {
    func testProgramsAndArguments() {
        let cases: [(String, [String])] = [
            ("cd android && ./gradlew assembleDebug", ["cd android", "gradlew assembleDebug"]),
            ("ANDROID_SERIAL=R5 adb install app.apk", ["adb install app.apk"]),
            ("xcrun simctl boot X", ["simctl boot X"]),
            ("xcrun --sdk iphoneos devicectl list devices", ["devicectl list devices"]),
            ("nice -n 10 caffeinate -i xcodebuild -scheme App", ["xcodebuild -scheme App"]),
            ("env FOO=1 npx expo run:ios", ["expo run:ios"]),
            ("pnpm exec agent-device open", ["agent-device open"]),
            ("node /x/agent-device.mjs press @e1", ["agent-device.mjs press @e1"]),
            ("yarn ios", ["yarn ios"]),
            ("(cd app; adb -s emu-1 shell)", ["cd app", "adb -s emu-1 shell"]),
            ("echo $(adb devices)", ["echo $", "adb devices"]),
            // Quoted separators and words stay in one word.
            (#"git commit -m "run; npx expo run:ios""#, ["git commit -m run; npx expo run:ios"]),
            (#"bash -c 'adb devices'"#, ["bash -c adb devices"]),
            // Comments and heredoc bodies are not commands.
            ("ls # npx expo run:ios", ["ls"]),
            ("cat > a.py <<'EOF'\nnpx expo run:ios\nEOF\nadb devices", ["cat > a.py", "adb devices"]),
            ("cat <<-END | wc\n\tgradlew build\n\tEND", ["cat", "wc"]),
            ("grep x <<< \"adb devices\"", ["grep x adb devices"]),
            // Redirections stay with their command.
            ("nohup npx expo start > /tmp/m.log 2>&1 &", ["expo start > /tmp/m.log 2>&1"]),
            ("adb logcat &>/tmp/l", ["adb logcat &>/tmp/l"]),
            // A heredoc inside a quoted $(…), with an odd quote in its body.
            ("gh pr create --body \"$(cat <<'EOF'\nit's \"done\nxcrun simctl shutdown all\nEOF\n)\"\nls",
             ["gh pr create --body $(cat <<'EOF'\n)", "ls"]),
            ("echo $((1<<2)); adb devices", ["echo $", "1 2", "adb devices"]),
            ("cat <<EOF-X\nadb devices\nEOF-X\nls", ["cat", "ls"]),
            ("adb devices\r\nls", ["adb devices", "ls"]),
            ("command -v xcodebuild", []),
        ]
        for (command, expected) in cases {
            let found = ShellCommand.invocations(command).map { ([$0.program] + $0.args).joined(separator: " ") }
            XCTAssertEqual(found, expected, command)
        }
        let adb = ShellCommand.invocations("A=1 B=x adb shell").first
        XCTAssertEqual(adb?.environment, ["A": "1", "B": "x"])
        XCTAssertEqual(ShellCommand.invocations("/t/s1/agent-device open").first?.path, "/t/s1/agent-device")
    }

    func testWhatReachesDevDeck() {
        func preToolUse(_ command: String) -> [String: Any] {
            ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": command]]
        }
        XCTAssertTrue(HookProtocol.isRelevant(preToolUse("cd app && npx expo run:ios")))
        XCTAssertTrue(HookProtocol.isRelevant(preToolUse("$ANDROID_HOME/platform-tools/adb devices")))
        XCTAssertTrue(HookProtocol.isRelevant(["hook_event_name": "PreToolUse", "tool_name": "mcp__argent__gesture-tap"]))
        XCTAssertTrue(HookProtocol.isRelevant(["hook_event_name": "Stop"]))
        XCTAssertFalse(HookProtocol.isRelevant(preToolUse("grep -r adb README.md")))
        XCTAssertFalse(HookProtocol.isRelevant(preToolUse("cat > notes.md <<EOF\nnpx expo run:ios\nEOF")))
        XCTAssertFalse(HookProtocol.isRelevant(["hook_event_name": "PreToolUse", "tool_name": "Read"]))
        XCTAssertFalse(HookProtocol.isRelevant([
            "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_response": ["stdout": "ok"],
        ]))
        XCTAssertTrue(HookProtocol.isRelevant([
            "hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "error": "Error (DEVICE_IN_USE): …",
        ]))
    }

    /// Every command DevDeck acts on has to get past the hook's cheap filter first.
    func testEveryCommandDevDeckReadsReachesIt() {
        let commands = [
            "xcrun simctl boot X", "adb -s emulator-5554 shell input tap 1 1", "emulator -avd Pixel_9",
            "xcrun devicectl device install app --device X a.app", "agent-device open app", "./gradlew assembleDebug",
            "xcodebuild -scheme A build", "npx expo run:ios", "npx react-native start", "eas build --local",
            "yarn ios", "pnpm dev", "bunx vite", "next dev", "storybook dev", "npx kill-port 8081", "fuser -k 8081/tcp",
            "kill 4122", "killall Simulator", "pkill -f qemu", "sudo launchctl kickstart -k system/com.apple.CoreSimulatorService",
        ]
        for command in commands {
            XCTAssertTrue(HookProtocol.isRelevant([
                "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": command],
            ]), command)
        }
    }
}
