import DevDeckProtocol
import Foundation

/// Kinds of heavy work that share the Mac. Each has a limit; agents wait for room.
enum Pool: String, CaseIterable, Identifiable, Hashable {
    case iosSimulator, androidEmulator, build, devServer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iosSimulator: "iOS simulators"
        case .androidEmulator: "Android emulators"
        case .build: "Native builds"
        case .devServer: "Dev servers"
        }
    }

    /// "1 native build", "2 iOS simulators"
    func count(_ n: Int) -> String {
        switch self {
        case .iosSimulator: n == 1 ? "1 iOS simulator" : "\(n) iOS simulators"
        case .androidEmulator: n == 1 ? "1 Android emulator" : "\(n) Android emulators"
        case .build: n == 1 ? "1 native build" : "\(n) native builds"
        case .devServer: n == 1 ? "1 dev server" : "\(n) dev servers"
        }
    }

    var defaultLimit: Int {
        switch self {
        case .iosSimulator: 2
        case .androidEmulator: 1
        case .build: 1
        case .devServer: 3
        }
    }

    /// Memory one more of these typically takes: a booted simulator with an app, an
    /// emulator with its guest RAM, a native build at its peak, a Metro or Vite server.
    var typicalFootprint: UInt64 {
        switch self {
        case .iosSimulator: 2560 << 20
        case .androidEmulator: 3 << 30
        case .build: 4 << 30
        case .devServer: 768 << 20
        }
    }

    // MARK: - Recognizing heavy work

    /// Pools an argent tool call needs: booting a device.
    static func forArgent(_ tool: String, _ input: [String: Any]) -> [Pool] {
        guard tool == "boot-device" else { return [] }
        if input["avdName"] != nil { return [.androidEmulator] }
        if let udid = input["udid"] as? String, UUID(uuidString: udid) != nil { return [.iosSimulator] }
        return []
    }

    /// Pools a shell command needs: builds, dev servers and device boots.
    static func forShell(_ command: String) -> [Pool] {
        var pools: [Pool] = []
        for invocation in ShellCommand.invocations(command) {
            if let pool = pool(program: invocation.program, args: invocation.args), !pools.contains(pool) {
                pools.append(pool)
            }
        }
        return pools
    }

    private static let devScripts: Set<String> = ["start", "dev", "web", "serve"]
    private static let buildScripts: Set<String> = ["ios", "android"]

    private static func pool(program: String, args: [String]) -> Pool? {
        switch program {
        case "xcodebuild":
            let info = [
                "-list", "-version", "-showsdks", "-showBuildSettings", "-showdestinations", "-help", "-usage",
                "test-without-building",
            ]
            return args.contains(where: info.contains) ? nil : .build
        case "gradlew", "gradle":
            if args.contains(where: { ["--stop", "--status", "--version", "tasks"].contains($0) }) { return nil }
            let tasks = args.filter { !$0.hasPrefix("-") }
            let building = tasks.contains { $0.range(of: "assemble|install|build|bundle|test|connected|lint", options: [.regularExpression, .caseInsensitive]) != nil }
            return building ? .build : nil
        case "expo":
            if let verb = args.first {
                if verb.hasPrefix("run:") { return .build }
                if verb == "start" { return .devServer }
            }
            return nil
        case "react-native":
            if let verb = args.first {
                if verb.hasPrefix("run-") { return .build }
                if verb == "start" { return .devServer }
            }
            return nil
        case "eas":
            return args.first == "build" && args.contains("--local") ? .build : nil
        case "npm", "yarn", "pnpm", "bun":
            // npm start, npm run dev, yarn dev, yarn run ios, pnpm android, bun run dev
            var rest = args.filter { !$0.hasPrefix("-") }
            if rest.first == "run" { rest.removeFirst() }
            guard let script = rest.first else { return nil }
            if devScripts.contains(script) { return .devServer }
            if buildScripts.contains(script) { return .build }
            return nil
        case "vite":
            return args.first.map { ["build", "preview", "optimize"].contains($0) } == true ? nil : .devServer
        case "next", "nuxt", "astro", "remix":
            return args.first == "dev" ? .devServer : nil
        case "storybook":
            return args.first == "dev" ? .devServer : nil
        case "start-storybook", "metro":
            return .devServer
        case "simctl":
            return args.first == "boot" ? .iosSimulator : nil
        case "emulator":
            return args.contains("-avd") || args.contains(where: { $0.hasPrefix("@") }) ? .androidEmulator : nil
        default:
            return nil
        }
    }
}
