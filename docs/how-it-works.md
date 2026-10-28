# How DevDeck works

## Finding devices and servers

- **Devices:** `xcrun simctl`, `xcrun devicectl`, `adb` and `emulator` (the Android SDK at
  `$ANDROID_HOME` or `~/Library/Android/sdk`). Refreshed every 5 seconds; physical iOS
  devices every 15.
- **Dev servers:** listening TCP ports from `lsof`, owned by a script runtime (node, bun,
  deno, python, ruby, php), excluding runtimes bundled inside apps (editor helpers,
  Electron backends). The project name is the git repo the server runs in, and worktrees
  are named too. Metro is recognized by its `/status` endpoint, and `/json/list` gives
  the apps connected to it. Agent tools such as the argent tool-server are listed apart.
- **Reload** sends a `reload` broadcast on Metro's `/message` WebSocket, which is what
  pressing `r` in the Metro terminal does. It works with Expo and React Native CLI.
- **Stop** sends SIGTERM to the server, its child processes and the wrappers that
  launched it (`npm run`, `npx`, `yarn`, `pnpm`, `sh -c`), and SIGKILL to anything still
  alive after 3 seconds. The shell, terminal or agent above the wrappers is left alone,
  and so is DevDeck itself.

In the dashboard, Stop and Shut Down ask for a second click to confirm. While the
dashboard is open, DevDeck acts as a regular app (Dock icon, menu bar, ⌘-Tab, ⌘1, ⌘2…
for the pages); closing it goes back to the menu bar only.

## Agent hooks

**General → Agent Activity** adds three hooks to `~/.claude/settings.json` (and, for
Codex, `~/.codex/hooks.json`):

| Hook | When | What it does |
|---|---|---|
| `PreToolUse` (argent tools and `Bash`) | before each call | asks DevDeck whether the call may run, and waits for the answer |
| `Stop` | the agent's turn ended | lets queued users and waiting agents take its devices |
| `SessionEnd` | the session ended | ends its leases |

The hooks run `devdeck-hook`, a small helper inside the app, which talks to DevDeck over
a socket in `~/Library/Application Support/DevDeck`. Only argent tool calls and shell
commands that mention `simctl`, `adb`, `emulator`, a build tool or a dev server reach
DevDeck; anything else returns at once. If DevDeck isn't running, or crashes, the helper
lets every call through. DevDeck rewrites the hooks when it's updated or moved, and
leaves the rest of the settings file as it is.

DevDeck reads the device from argent's `udid` / `device_id` arguments, from
`xcrun simctl … <udid|booted>`, `adb -s <serial>` (or the only connected device) and
`emulator -avd <name>`. Commands that reach a device indirectly, such as `npm run ios`,
aren't tied to a device, but they do count as builds (see Resources).

## Leases

- An agent that acts on a device **leases** it. The lease ends after 10 minutes without a
  call, when the session ends, or when the device stops. Subagents count as their parent
  session.
- **Agents wait for each other.** Another agent's calls on a leased device wait until the
  holder's turn ends, its session ends, or it's been quiet for 2 minutes. If a free
  simulator or emulator of the same kind is running, the call is turned away at once
  and the agent is told to use that one instead.
- **You come first.** **Hold Device** or **Take Over Now** makes agent calls on the device
  wait until you **Release** it, or until you've been away from the Mac (no keyboard or
  mouse input) for 10 minutes; see General → Release my holds. **Join Queue** makes a
  device yours as soon as the agent is done with it, and DevDeck sends a notification.
- A call waits up to 9 minutes. Then it's turned away, and the agent reads why and which
  devices are free. On the **Leases** page you can also let a waiting call go next
  (**Move to Front**) or turn it away now (**Turn Away**).

## Resources

Heavy work an agent starts waits for room. Each kind has a limit, set on the
**Resources** page:

| Kind | Default | Recognized from |
|---|---|---|
| iOS simulators | 2 booted | `simctl boot`, argent `boot-device` |
| Android emulators | 1 running | `emulator -avd`, argent `boot-device` |
| Native builds | 1 | `xcodebuild`, Gradle builds, `expo run`, `react-native run-*`, `npm run ios`/`android`, local EAS builds |
| Dev servers | 3 | `expo start`, `npm`/`yarn`/`pnpm`/`bun` `start`/`dev`, Vite, Next.js, Storybook, Metro |

While free memory is below 15% (or macOS reports memory pressure), nothing heavy starts.
DevDeck counts what's actually running, your own work included, but only agents are
held back. A call that gets through reserves its room for a minute, until its process
shows up. **Run Now** on the Resources page lets a waiting call start anyway.

**Run builds at background priority** (off by default) puts native builds and the
Gradle daemons doing their work on the efficiency cores with throttled disk access
while you're at the Mac: builds take longer, the Mac stays smooth. **Stop Idle Daemons**
ends Gradle and Kotlin daemons that keep gigabytes of memory between builds.

## Device markers

When an agent first drives a simulator or emulator, DevDeck installs a small DevDeck
companion app on it (see [helpers/](../helpers/README.md)) and keeps it told who holds
the device:

- **iOS simulators:** a Live Activity in the Dynamic Island, with a chip and the agent's
  name while an agent drives it, a person and "You" while you hold it, and an empty
  island otherwise. iOS only lets an app start a Live Activity from the front, so DevDeck
  starts it right after a simulator boots: the companion opens and steps straight back
  to the home screen. For a simulator that was already running, use **Start Device
  Marker** in its menu.
- **Android emulators:** a silent notification with a small status bar icon, which you
  can swipe away.

Physical devices get no marker. Turn markers off in General → Agent Activity, or on the
device in the companion app.

## The socket

Scripts can use the same socket as the hooks, one JSON line per connection:

```json
{"command": "hold" | "release" | "queue" | "leave", "device": "<udid or serial>"}
{"command": "front" | "run" | "dismiss", "waiter": "<id from status>"}
{"command": "status"}
```

For example:

```bash
echo '{"command": "status"}' | nc -U ~/Library/Application\ Support/DevDeck/broker.sock
```

## Agent sounds

DevDeck reads and writes peon-ping's own `config.json` and `.paused` files, so changes
made with the `peon` CLI show up in the app and the other way round. Per-sound volume and
per-app control need a `peon.sh` that supports `category_volumes` / `disabled_clients`;
with an older one those controls are disabled. `CLAUDE_PEON_DIR` points DevDeck at a
different peon-ping data folder. Without peon-ping, the sound controls are hidden, and
they appear once it's installed.
