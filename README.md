# DevDeck

A macOS menu bar app for the things coding agents and dev work leave running:
simulators and devices, dev servers, and agent sound notifications (peon-ping).

**Menu (click the menu bar icon)**

A native macOS menu, so it looks and behaves like the system's own.
- Agent sounds: mute all, volume, voice pack, per-sound volume
- Running devices: hover one for Shut Down / Stop; "Start a Device" boots a simulator or emulator
- Running dev servers (project, kind, port, uptime): hover one for Reload Apps (Metro),
  Stop, Open in Browser, Reveal in Finder, Open in Terminal
- The number next to the icon is how many dev servers are running; the icon dims while
  sounds are muted. General in the dashboard has a choice of icons.

**Dashboard window** (laid out like System Settings)
- Devices: iOS simulators (boot / shut down), Android emulators (start / stop),
  paired iPhones/iPads and adb devices
- Dev Servers: Metro (Expo / React Native, with the apps connected to it), Vite,
  Next.js, Storybook and other servers run by node, bun, deno, python, ruby or php;
  agent tools such as the argent tool-server are listed separately. Reload on a Metro
  server reloads the apps connected to it, like pressing `r` in its terminal. The ⓘ button shows
  a server's folder, command and PID; right-click to open it in the browser, Finder or Terminal.
- Agent Sounds, Voice Packs, Agent Apps: peon-ping settings (see below)
- General: open at login, menu bar icon, peon-ping info

In the dashboard, Stop and Shut Down ask for a second click to confirm. While the dashboard
is open DevDeck acts as a regular app (Dock icon, menu bar, ⌘-Tab, ⌘1–⌘6 for the pages);
closing it goes back to menu bar only.

## How it finds things

- Devices: `xcrun simctl`, `xcrun devicectl`, `adb` and `emulator` (Android SDK at
  `$ANDROID_HOME` or `~/Library/Android/sdk`). Refreshed every 5 seconds; physical
  iOS devices every 15.
- Dev servers: listening TCP ports from `lsof`, owned by a script runtime, excluding
  runtimes bundled inside apps (editor helpers, Electron backends). The project name
  is the git repo the server runs in (worktrees are named too). Metro is recognized
  by its `/status` endpoint, and `/json/list` gives the connected apps.
- Reload sends a `reload` broadcast on Metro's `/message` WebSocket, which is what
  pressing `r` in the Metro terminal does. Works with both Expo and React Native CLI.
- Stop sends SIGTERM to the server, its child processes and the wrappers that launched
  it (`npm run`, `npx`, `yarn`, `pnpm`, `sh -c`), and SIGKILL to anything still alive
  after 3 seconds. The shell, terminal or agent above the wrappers is left alone, and so
  is DevDeck itself.

## Agent activity

DevDeck shows which simulator or device a coding agent is driving: the device turns
purple, with the agent, its last action and the project ("Claude Code · gesture-tap 12 s
ago · my-app"), so you know to leave it alone. Turn it on per agent in
General → Agent Activity (or `open -a DevDeck --args --hooks claude,codex`).

- It adds `PreToolUse`, `Stop` and `SessionEnd` hooks to `~/.claude/settings.json` and
  `~/.codex/hooks.json`. They run `devdeck-hook` (inside the app), which sends argent
  tool calls and `xcrun simctl` / `adb` / `emulator` commands to a socket in
  `~/Library/Application Support/DevDeck`. Codex skips new or changed hooks until you
  trust them in `/hooks`.
- A device counts as driven until the agent has been idle on it for 10 minutes, its
  session ends, or the device is shut down.

**Holding a device.** From a device's menu (or the button on its row in the dashboard):

- **Hold Device** keeps agents off a free device. **Take Over Now** does the same for
  one an agent is driving. An agent's next call on a held device waits until you
  **Release** it, or until you've been away from the Mac (no keyboard or mouse input)
  for 10 minutes (General → Release my holds).
- **Join Queue** makes the device yours as soon as the agent is done with it: its turn
  ends, its session ends, or it's idle for 10 minutes. DevDeck sends a notification.
- A call waits up to 9 minutes; then it's refused and the agent is told the device is
  in use and which devices are free.
- If DevDeck isn't running (or crashes), nothing waits.

**Agents sharing devices.** An agent keeps a device while it works. Another agent's
calls on it wait until the first agent's turn ends, its session ends, or it's been quiet
for 2 minutes. If a free simulator or emulator of the same kind is running, the second
agent is turned away at once and told to use that one instead. Your holds and your place
in the queue come before any agent. Subagents count as their parent session.

The **Leases** page in the dashboard shows each device's holder and the line waiting for
it, with Take Over, Release, Move to Front (let a waiting call go next) and Turn Away (the
agent is told the device is in use).
- Scripts can do the same over the socket, one JSON line per connection:
  `{"command": "hold" | "release" | "queue" | "leave", "device": "<udid or serial>"}`,
  `{"command": "front" | "run" | "dismiss", "waiter": "<id from status>"}` or `{"command": "status"}`.

**Keeping the Mac responsive.** Heavy work an agent starts waits for room. Each kind
has a limit, set on the **Resources** page: booted iOS simulators (2), running Android
emulators (1), native builds (1: `xcodebuild`, Gradle builds, `expo run`,
`react-native run-*`, local EAS builds) and dev servers (3: `expo start`, `npm run dev`,
Vite, Next.js…). While memory is low (below 15% free by default, or macOS reports memory
pressure), nothing heavy starts. DevDeck counts what's actually running, your own work
included, but only agents are held back. A call that gets through reserves its room for
a minute, until its process shows up. The Resources page also shows the Mac's load,
lists calls waiting for room (Run Now, Turn Away), stops idle Gradle and Kotlin daemons,
and can run builds at background priority while you're at the Mac.

**Device markers.** DevDeck also shows it on the device, through a small DevDeck
companion app (see `helpers/`) that it installs when an agent first drives a simulator
or emulator:

- iOS simulators: a Live Activity in the Dynamic Island, with a chip and "Claude" while
  an agent drives it, and an empty island otherwise. iOS only lets an app start a Live
  Activity from the front, so DevDeck starts it right after a simulator boots (the
  companion opens and steps back to the home screen). For a simulator that was already
  running, use "Start Device Marker" in its menu.
- Android emulators: a silent notification with a small status bar icon, which you can
  swipe away.
- Physical devices get no marker. Turn markers off in General → Agent Activity, or on
  the device in the DevDeck companion.

## Agent sounds

DevDeck reads and writes peon-ping's own `config.json` and `.paused` files, so changes
made with the `peon` CLI show up in the app and the other way round. Per-sound volume
and per-client control need a `peon.sh` that supports `category_volumes` /
`disabled_clients`; with an older one those controls are disabled. Set
`CLAUDE_PEON_DIR` to point the app at a different peon-ping data directory.

peon-ping is optional. Without it (no `peon.sh` in its data directory) the Agent Sounds
menu section and the three sound pages are hidden, and they appear on their own once
peon-ping is installed.

## Build

Requires Xcode (or its command line tools).

```bash
bash scripts/build-app.sh            # builds build/DevDeck.app
bash scripts/build-app.sh --install  # also copies it to ~/Applications and launches it
swift test                           # scanner and stop logic, including a real server
```

Requires macOS 26 or later, and must be built with its SDK or newer: apps linked against
an older SDK run in compatibility mode, without the current menu and sidebar materials.

To open a window at launch (handy for screenshots), pass `--open`:

```bash
open ~/Applications/DevDeck.app --args --open dashboard:servers   # pages: devices, servers, sounds, packs, clients, general
```

The menu bar icons are filled icons from [Tabler Icons](https://tabler.io/icons) (MIT).
