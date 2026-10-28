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

## Agent sounds

DevDeck reads and writes peon-ping's own `config.json` and `.paused` files, so changes
made with the `peon` CLI show up in the app and the other way round. Per-sound volume
and per-client control need a `peon.sh` that supports `category_volumes` /
`disabled_clients`; with an older one those controls are disabled. Set
`CLAUDE_PEON_DIR` to point the app at a different peon-ping data directory.

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
