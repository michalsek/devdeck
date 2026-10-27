# DevDeck

A macOS menu bar app for the things coding agents and dev work leave running:
simulators and devices, dev servers, and agent sound notifications (peon-ping).

**Menu (click the menu bar icon)**
- Agent sounds: mute all, volume, voice pack, per-sound volume
- Running devices, with Shut Down / Stop
- Running dev servers (project, kind, port, uptime), with Stop
- The number next to the icon is how many dev servers are running

**Dashboard window**
- Devices: iOS simulators (boot / shut down), Android emulators (start / stop),
  paired iPhones/iPads and adb devices
- Dev Servers: Metro (Expo / React Native, with the apps connected to it), Vite,
  Next.js, Storybook and other servers run by node, bun, deno, python, ruby or php;
  agent tools such as the argent tool-server are listed separately. Select one for
  its folder, command and PID; right-click to open it in the browser, Finder or Terminal.
- Sounds, Voice Packs, Clients: peon-ping settings (see below)
- General: open at login, peon-ping info

Stop and Shut Down ask for a second click to confirm.

## How it finds things

- Devices: `xcrun simctl`, `xcrun devicectl`, `adb` and `emulator` (Android SDK at
  `$ANDROID_HOME` or `~/Library/Android/sdk`). Refreshed every 5 seconds; physical
  iOS devices every 15.
- Dev servers: listening TCP ports from `lsof`, owned by a script runtime, excluding
  runtimes bundled inside apps (editor helpers, Electron backends). The project name
  is the git repo the server runs in (worktrees are named too). Metro is recognized
  by its `/status` endpoint, and `/json/list` gives the connected apps.
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

Requires macOS 14+ and Xcode (or its command line tools).

```bash
bash scripts/build-app.sh            # builds build/DevDeck.app
bash scripts/build-app.sh --install  # also copies it to ~/Applications and launches it
swift test                           # scanner and stop logic, including a real server
```

To render the menu and every dashboard page to PNGs without clicking through them
(debug builds only):

```bash
swift build
DEVDECK_SNAPSHOT_DIR=/tmp/shots .build/debug/DevDeck
```
