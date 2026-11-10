import Foundation

/// One program run by a shell command, e.g. `adb -s emulator-5554 install app.apk` out of
/// `cd android && ANDROID_SERIAL=… adb install app.apk`.
public struct ShellInvocation: Equatable, Sendable {
    /// The program's file name: "adb", "simctl", "agent-device".
    public let program: String
    /// The program as typed, e.g. a T3 Code launcher's full path.
    public let path: String
    public let args: [String]
    /// Leading `NAME=value` assignments.
    public let environment: [String: String]
    /// The part of the command this came from, e.g. "npx expo run:ios --device X".
    public let text: String
    /// Every word of that part, unquoted: assignments and runners included.
    public let words: [String]
}

/// Reads the programs a shell command runs. Best effort, not a shell: the command is cut
/// into parts at `;`, `&`, `|`, `(`, `)` and newlines outside quotes, quotes are removed
/// from words, comments and heredoc bodies are skipped, and runners that just start the
/// next word are looked through (`npx expo`, `xcrun simctl`, `nice -n 10 xcodebuild`,
/// `node …/agent-device.mjs`).
public enum ShellCommand {
    public static func invocations(_ command: String) -> [ShellInvocation] {
        parts(command).compactMap { invocation($0.words, text: $0.text) }
    }

    // MARK: Words

    private static func parts(_ command: String) -> [(words: [String], text: String)] {
        let chars = Array(command.replacingOccurrences(of: "\r\n", with: "\n"))
        var parts: [(words: [String], text: String)] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var heredocs: [String] = []
        var partStart = 0
        var i = 0

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endPart(at end: Int) {
            endWord()
            if !words.isEmpty {
                let upper = min(end, chars.count)
                let text = String(chars[min(partStart, upper)..<upper]).trimmingCharacters(in: .whitespaces)
                parts.append((words, text))
            }
            words = []
            partStart = end + 1
        }
        /// The index of the next newline at or after `index`, or the end.
        func lineEnd(from index: Int) -> Int {
            var end = index
            while end < chars.count, chars[end] != "\n" { end += 1 }
            return end
        }
        /// For `<<` at `i`: the heredoc's delimiter and the index after it. `<<<` (a
        /// here-string) and `<<` followed by something that can't start a delimiter (as in
        /// `$((1<<2))`) are not heredocs.
        func heredoc(at i: Int) -> (delimiter: String, next: Int)? {
            var j = i + 2
            guard j <= chars.count, j == chars.count || chars[j] != "<" else { return nil }
            if j < chars.count, chars[j] == "-" { j += 1 }
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            var delimiter = ""
            if j < chars.count, chars[j] == "'" || chars[j] == "\"" {
                let close = chars[j]
                j += 1
                while j < chars.count, chars[j] != close, chars[j] != "\n" {
                    delimiter.append(chars[j])
                    j += 1
                }
                if j < chars.count, chars[j] == close { j += 1 }
            } else {
                guard j < chars.count, chars[j] == "_" || chars[j].isLetter else { return nil }
                while j < chars.count, !" \t\n;|&<>()\"'".contains(chars[j]) {
                    delimiter.append(chars[j])
                    j += 1
                }
            }
            return delimiter.isEmpty ? nil : (delimiter, j)
        }
        /// Skips the bodies of pending heredocs after the newline at `i`; returns the index of
        /// the newline that ends the last delimiter line (or the end).
        func skipHeredocs(from i: Int) -> Int {
            var index = i
            for delimiter in heredocs {
                var line = index + 1
                while line < chars.count {
                    let end = lineEnd(from: line)
                    index = end
                    if String(chars[line..<end]).trimmingCharacters(in: .whitespaces) == delimiter { break }
                    line = end + 1
                }
                if line >= chars.count { index = chars.count }
            }
            heredocs = []
            return index
        }

        while i < chars.count {
            let c = chars[i]
            if let open = quote {
                if c == open {
                    quote = nil
                } else if c == "\\", open == "\"", i + 1 < chars.count {
                    i += 1
                    word.append(chars[i])
                } else if open == "\"", c == "<", i + 1 < chars.count, chars[i + 1] == "<", let found = heredoc(at: i) {
                    // A heredoc inside "$(cat <<'EOF' … EOF)": its body may hold quotes.
                    heredocs.append(found.delimiter)
                    word.append(contentsOf: chars[i..<found.next])
                    i = found.next
                    continue
                } else if c == "\n", !heredocs.isEmpty {
                    word.append(c)
                    i = skipHeredocs(from: i)
                } else {
                    word.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                inWord = true
            case "\\":
                if i + 1 < chars.count {
                    i += 1
                    if chars[i] != "\n" {
                        word.append(chars[i])
                        inWord = true
                    }
                }
            case " ", "\t":
                endWord()
            case "#" where !inWord:
                // A comment runs to the end of the line.
                i = lineEnd(from: i) - 1
            case "\n":
                endPart(at: i)
                // Heredoc bodies are data, not commands.
                if !heredocs.isEmpty { i = skipHeredocs(from: i) }
                partStart = i + 1
            case "&" where inWord && (word.last == ">" || word.last == "<"),
                 "&" where i + 1 < chars.count && chars[i + 1] == ">":
                // A redirection: 2>&1, <&3, &>file.
                word.append(c)
                inWord = true
            case ";", "|", "&", "(", ")":
                endPart(at: i)
            case "<" where i + 1 < chars.count && chars[i + 1] == "<":
                endWord()
                if let found = heredoc(at: i) {
                    heredocs.append(found.delimiter)
                    i = found.next - 1
                } else {
                    // A here-string (<<<) or a shift: skip the operator.
                    while i + 1 < chars.count, chars[i + 1] == "<" { i += 1 }
                }
            default:
                word.append(c)
                inWord = true
            }
            i += 1
        }
        endPart(at: chars.count)
        return parts
    }

    // MARK: Programs

    private static func invocation(_ allWords: [String], text: String) -> ShellInvocation? {
        var words = allWords
        var environment: [String: String] = [:]
        func takeAssignments() {
            while let first = words.first, let (name, value) = assignment(first) {
                environment[name] = value
                words.removeFirst()
            }
        }
        takeAssignments()
        // `command -v xcodebuild` only asks where a program is.
        if words.first == "command", let flag = words.dropFirst().first, flag == "-v" || flag == "-V" { return nil }
        while let first = words.first {
            let name = fileName(first)
            if let flags = runners[name] {
                words.removeFirst()
                skipFlags(&words, valued: flags)
                if name == "env" { takeAssignments() }
            } else if let second = words.dropFirst().first, pairedRunners.contains(name + " " + second) {
                words.removeFirst(2)
            } else if name == "node", let script = words.dropFirst().first, !script.hasPrefix("-") {
                words.removeFirst()
            } else {
                break
            }
        }
        guard let path = words.first else { return nil }
        return ShellInvocation(
            program: fileName(path), path: path, args: Array(words.dropFirst()), environment: environment, text: text,
            words: allWords)
    }

    /// Runners that start the next word, with their flags that take a value.
    private static let runners: [String: Set<String>] = [
        "npx": [], "bunx": [], "pnpx": [], "exec": [], "command": [], "nohup": [], "time": [],
        "caffeinate": ["-t", "-w"], "nice": ["-n"], "env": ["-u", "-C", "-S"],
        "xcrun": ["-sdk", "--sdk", "-toolchain", "--toolchain"],
        "xargs": ["-n", "-I", "-P", "-L", "-s", "-E", "-d"], "sudo": ["-u", "-g", "-C", "-h", "-p"],
    ]
    private static let pairedRunners: Set<String> = [
        "pnpm exec", "pnpm dlx", "yarn exec", "yarn dlx", "npm exec", "bun x",
    ]

    private static func skipFlags(_ words: inout [String], valued: Set<String>) {
        while let flag = words.first, flag.hasPrefix("-") {
            words.removeFirst()
            if valued.contains(flag), !words.isEmpty { words.removeFirst() }
        }
    }

    /// `ANDROID_SERIAL=emulator-5554` → ("ANDROID_SERIAL", "emulator-5554")
    private static func assignment(_ word: String) -> (String, String)? {
        guard let equals = word.firstIndex(of: "=") else { return nil }
        let name = word[..<equals]
        guard let first = name.first, first == "_" || first.isLetter,
              name.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber })
        else { return nil }
        return (String(name), String(word[word.index(after: equals)...]))
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
