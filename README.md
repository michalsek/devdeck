<p align="center">
  <img src="docs/images/icon.png" width="128" alt="DevDeck icon">
</p>

<h1 align="center">DevDeck</h1>

<p align="center">
  A macOS menu bar app that keeps simulators, dev servers and coding agents in check.
</p>

<p align="center">
  <img src="docs/images/menu.png" width="330" alt="The DevDeck menu">
  <img src="docs/images/leases.png" width="520" alt="The Leases page of the DevDeck dashboard">
</p>

Coding agents that build and test mobile apps boot simulators, start dev servers and kick
off native builds, often several agents at once, on the same Mac you're working on.
DevDeck shows what's running and lets you stop what's left over. It also tells you which
device an agent is driving, and makes agents take turns: with you, with each other, and
with your Mac's memory.

## Features

- **Devices.** iOS simulators, Android emulators and connected iPhones and Android
  phones in one list. Boot, shut down and start them from the menu.
- **Dev servers.** Finds Metro, Vite, Next.js and other dev servers by their listening
  ports and names them after their project. **Stop** ends the whole process tree, and
  **Reload** reloads the apps connected to Metro, like pressing `r` in its terminal.
- **Agents.** Every agent session DevDeck has heard from: what it's doing, the devices it
  holds or booted, and the Metros, builds and Gradle daemons it started. When a session
  ends and leaves things running, **Clean Up** stops them.
- **Agent activity.** See which simulator or device a Claude Code agent is driving, and
  what it last did. The device turns purple. Under each device: the Metro its app loads
  (flagged when it isn't the agent's checkout), and how the agent's last build, install or
  launch on it went.
- **Device leases.** **Hold** a device, **take it over** from an agent, or **join the
  queue** for it. Agents wait for you, and for each other. An agent that finds a device
  busy, or wants to boot another simulator while one is free, is sent to the free one.
- **agent-device claims.** Devices claimed by [agent-device](https://www.npmjs.com/package/agent-device)
  sessions (T3 Code's device tools) show who holds them. A claim whose agent has finished
  is marked stale and can be released with one click, and an agent turned away with
  `DEVICE_IN_USE` is told who holds the device and whether waiting will help.
- **Guardrails.** Commands that affect every agent (`killall Simulator`, `simctl shutdown
  all`, `adb kill-server`) or stop another agent's server wait for your OK. Optionally,
  agents test Android on your phone only. A call for a locked or untrusted phone waits
  until you've unlocked it.
- **Metro, kept running.** When an agent starts Metro, DevDeck runs it instead, so the
  agent's background task ending doesn't take it down, and picks a free port when the
  usual one belongs to another project.
- **Activity.** What DevDeck decided about your agents, for the last week.
- **Notifications.** When an agent has to wait, a notification says which one and why,
  with **Let Through** and **Turn Away** buttons. The menu bar icon counts waiting calls.
- **On-device markers.** A small companion app shows who's driving a simulator in the
  Dynamic Island (a Live Activity), or as a silent notification on Android emulators.
- **Resources.** Limits on booted simulators, emulators, native builds and dev servers that
  shrink to leave memory for your own apps (browsers, chat, games) and while a game is in
  front, plus a low-memory and swap check: agents wait for room instead of grinding your
  Mac to a halt.
  It also stops idle Gradle and Kotlin daemons, and can run builds at background
  priority while you're at the Mac.
- **Agent sounds.** A voice line when an agent starts, finishes, fails or needs you, and a
  notification unless its app is in front. Uses [peon-ping](https://github.com/PeonPing/peon-ping)
  voice packs; **Switch from peon-ping** moves its packs and settings over. See
  [adding sound packs](docs/sound-packs.md).
- **Native.** A real macOS menu and a dashboard laid out like System Settings, with
  Liquid Glass on macOS 26.

## Screenshots

| Devices | Resources |
|---|---|
| ![Devices](docs/images/devices.png) | ![Resources](docs/images/resources.png) |

| Dev Servers | Device markers in the Dynamic Island |
|---|---|
| ![Dev Servers](docs/images/servers.png) | ![An agent driving the simulator, then the user holding it](docs/images/marker-ios.png) |

## Requirements

- macOS 26 or later, and Xcode 26 or later to build it.
- Optional: the Android SDK for emulators and Android devices,
  [Claude Code](https://claude.com/claude-code) for agent activity and leases,
  [argent](https://github.com/software-mansion/argent) (DevDeck understands its device
  tools).

## Build and install

```bash
git clone https://github.com/michalsek/devdeck.git
cd devdeck
bash scripts/build-app.sh --install   # builds DevDeck.app, copies it to ~/Applications and opens it
```

The first build also builds the companion apps, so it takes a few minutes. To keep macOS
from asking for folder access again after every rebuild, sign with your development
certificate; see [docs/development.md](docs/development.md#signing).

## Getting started

1. Click the menu bar icon for devices, dev servers and resources at a glance. The
   number next to the icon is how many dev servers are running.
2. Choose **Open Dashboard…** (⌘,) for everything else.
3. Turn on **General → Agent Activity → Claude Code**. DevDeck adds hooks to
   `~/.claude/settings.json`, and from then on devices that agents drive are marked.
   If DevDeck isn't running, the hooks do nothing.
4. To keep agents off a device, choose **Hold Device** in its menu, or **Take Over** on
   one an agent is using. Release it when you're done; your hold also ends after you've
   been away from the Mac for a while.
5. Set the limits for heavy work on the **Resources** page.

Codex hooks work the same way but are experimental; Codex asks you to trust them in
`/hooks`.

## Learn more

- [How it works](docs/how-it-works.md): how DevDeck finds things, the lease and queue
  rules, resource limits, device markers and the socket scripts can use.
- [Development](docs/development.md): building, signing, tests, demo mode and the
  project layout.
- [Companion apps](helpers/README.md): the iOS and Android marker apps.

## License

[MIT](LICENSE)
