# How DevDeck works

## Finding devices and servers

- **Refreshing.** Every scan runs on one shared tick that follows the agents: a hook call
  brings it to 5 seconds, and each tick without one doubles it, up to a minute. A call
  waiting for room keeps it at 5 seconds. Opening the menu or dashboard refreshes at once.
  Processes, ports and working directories are read from the kernel, not with `ps` or `lsof`.
- **Devices:** `simctl`, `devicectl` and `adb`; AVDs are the `.ini` files in `~/.android/avd`
  (the Android SDK at `$ANDROID_HOME` or `~/Library/Android/sdk`). Physical iOS devices
  refresh every 30 seconds at most.
- **Dev servers:** listening TCP ports, owned by a script runtime (node, bun,
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

**General → Agent Activity** adds these hooks to `~/.claude/settings.json` (and, for
Codex, `~/.codex/hooks.json`):

| Hook | When | What it does |
|---|---|---|
| `PreToolUse` (argent tools and `Bash`) | before each call | asks DevDeck whether the call may run, and waits for the answer |
| `PostToolUse`, `PostToolUseFailure` (`Bash`) | after a shell command | if agent-device answered `DEVICE_IN_USE`, adds what DevDeck knows about the device's holder (see agent-device claims); after a device build, install or launch, reports how it went |
| `Stop` | the agent's turn ended | lets queued users and waiting agents take its devices |
| `SessionEnd` | the session ended | ends its leases |
| `SessionStart`, `UserPromptSubmit`, `Notification`, `PermissionRequest`, `PreCompact` (Claude Code, with sounds on) | as named | plays agent sounds, in the background |

Codex has no `PostToolUseFailure`; its `PostToolUse` covers failed commands too.

The hooks run `devdeck-hook`, a small helper inside the app, which talks to DevDeck over
a socket in `~/Library/Application Support/DevDeck`. Only argent tool calls, shell
commands that run `simctl`, `devicectl`, `adb`, `emulator`, `agent-device`, a build tool,
a dev server or a `kill`, and the output of `DEVICE_IN_USE` errors and device builds
(only its last lines) reach DevDeck; anything else returns at once. Commands are read the
way a shell would split them: text in quotes, comments and heredocs isn't a command.
The helper also sends the agent's process id, to tell which processes it started, and
its `PATH`, to start Metro the way the agent would. If DevDeck isn't running, or crashes, the helper
lets every call through. DevDeck rewrites the hooks when it's updated or moved, and
leaves the rest of the settings file as it is.

DevDeck reads the device from argent's `udid` / `device_id` arguments, from
`xcrun simctl … <udid|booted>`, `adb -s <serial>` (or the only connected device),
`emulator -avd <name>` and `agent-device --udid / --serial`. T3 Code's device tools give
each thread its own `agent-device` launcher, bound to one device; DevDeck reads the device
from it, or from the claim of the launcher's session. Commands that reach a device indirectly, such as `npm run ios`,
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
- **Use what's running.** An agent that boots a simulator or emulator while one of the
  same kind is running and nobody uses it (the agent itself included: it boots another
  because it wants both) is turned away at once and told to use that one: each
  takes a few GB of memory. If it repeats the same boot within 5 minutes, DevDeck lets it
  through, since it needs that particular device. Before turning a boot away, DevDeck reads
  the device list again rather than trust one from a few seconds ago. A device a call is
  shutting down (`simctl shutdown <udid>`, `adb emu kill`) isn't free and doesn't count
  against the limits, so an agent that shuts one simulator down and boots another in its
  place goes straight through.
- A call waits up to 9 minutes. Then it's turned away, and the agent reads why and which
  devices are free. On the **Leases** page you can also let a waiting call go next
  (**Move to Front**) or turn it away now (**Turn Away**).

## agent-device claims

[agent-device](https://www.npmjs.com/package/agent-device), the CLI behind T3 Code's
device tools, keeps its own lock: a session that opens a device writes a claim to
`~/.agent-device/device-claims` (`AGENT_DEVICE_CLAIMS_DIR` moves it), and other sessions
get `DEVICE_IN_USE` until it closes. Nothing ends a session on its own: agent-device only
checks that the daemon holding it is alive, and T3 Code's daemon runs as long as T3 Code
does. A thread that finishes without closing its device keeps it until someone does.

- **Shown.** Every claim whose daemon is running appears on its device (Devices, Leases
  and the menu): the session, its project, and when it last ran a command (from the
  session's `events.ndjson`; the claim's own timestamp only moves on `open`). When DevDeck
  has seen the agent run that session's commands, it knows the agent too.
- **Stale.** A claim is marked stale when its agent's session has ended, when its agent's
  turn ended and the session has been quiet for 10 minutes since, or when the session has
  been quiet for 30 minutes.
- **Release Claim** closes the session through its daemon (the same `close` T3 Code
  sends, on the daemon's HTTP port with the token from its `daemon.json`), which frees
  the device. The agent that had it has to open the device again. The dashboard asks for
  a second click; the menu offers it only for stale claims. DevDeck releases a claim on its
  own only when the agent that opened it has ended its session (nobody is left to close
  it), and never deletes claim files: the daemon also remembers its sessions, so deleting
  the file wouldn't free the device.
- **Turned away.** When agent-device turns an agent's command away with `DEVICE_IN_USE`,
  DevDeck adds to what the agent reads: who holds the device and how long it's been
  quiet. For a claim in use, it says to leave it alone. For a stale one, it says waiting
  won't help, to ask the user, and which `close --session` command releases it if the user
  agrees. Free devices of the same kind are named either way. A stale claim also posts a
  notification with **Release Claim**.

## Agents

Each agent session that reaches DevDeck is listed on the **Agents** page, from its first
call until an hour after it ends.

- **Working, idle, ended.** A session is idle once its turn has been over for 30 minutes,
  and ended when it sends `SessionEnd` or its process is gone.
- **What it started.** Every few seconds DevDeck walks the agent's process tree for dev
  servers, native builds and Android emulators. They stay the session's after their
  parent shell exits. One whose shell exited before DevDeck saw it (`nohup … &`) is
  found by the session it was started in, which Claude Code puts in its environment
  (`CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`); subagents count as their parent. Simulators and emulators it boots count too, once the boot runs.
  Gradle and Kotlin daemons serve every build, so they're nobody's leftovers: stop idle
  ones on the Resources page. A new session in the same agent process (after `/clear`)
  carries on with what the previous one started.
- **Clean Up.** When a session ends with things still running, a notification lists them
  with **Clean Up**, which stops its processes and shuts down the devices it booted that
  nobody else holds, drives or has claimed. Nothing is stopped without your click.

## Guardrails

- **Commands that affect everyone** wait for your OK (**Let Through** or **Turn Away**,
  in a notification or on the Leases page; letting one through doesn't end your holds):
  `simctl shutdown all` / `erase all`; `adb kill-server`; restarting CoreSimulator; argent's
  `stop-all-simulator-servers` without a device list; and a kill that would stop something
  every agent uses: the Simulator app or Device Hub, CoreSimulator, the adb server, Gradle
  and Kotlin daemons, argent's tool server.
- **Stopping processes.** DevDeck judges a kill by the processes it would stop right now:
  for `kill <pid>`, `kill $(lsof -ti:<port>)`, `kill-port` and `fuser -k`, a dev server or
  build; for `pkill` and `killall`, everything the pattern matches, the way those tools
  match it. A process is the session's own if DevDeck saw the session start it (or the
  process that started it), it runs under the agent's process, or it's an emulator the
  session booted (also through argent).
  - Only the session's own, or nothing: it runs.
  - The session's own and others': it's turned away at once, with the `kill <pid>` that
    stops just its own.
  - Another agent's, or a dev server or build nobody DevDeck knows started: it waits a
    minute for your OK, then the agent is turned away and told whose they are.
  - Only other processes DevDeck can't tie to anyone (a browser the agent opened, say): it's
    turned away at once, with the pids to `kill` if they're the agent's.

  Notifications, the Leases page and Activity name the part of the command that's held and
  what it would stop.
- **Android on a phone.** With General → Android testing set to only physical phones,
  an agent that starts or drives an emulator is turned away and told to use the
  connected phone, or you're asked to connect one.
- **Phones that need you.** A call for a phone that's locked, doesn't trust the Mac,
  doesn't allow USB debugging yet or is offline waits until that's sorted, and you're
  told. A locked phone only holds calls that need it awake: installs and builds go ahead.
- **The wrong Metro.** The first time an agent acts on a device whose app loads another
  checkout's Metro, the call is turned away with how to point the app at the right one;
  asking again goes through. You're told too. A Metro the session started is its own,
  wherever it runs (a subagent's runs in its worktree).

## Metro

**Run agents' Metro servers in DevDeck** (Dev Servers, on by default): when an agent runs
`expo start`, `react-native start` or a package script that does (`npm start`,
`yarn dev`), on its own or after a `cd`, DevDeck starts that command itself in the same
folder, with the agent's `PATH`, in its own session (so quitting DevDeck doesn't stop it),
and logs to `~/Library/Logs/DevDeck` in place of the command's own redirections. A
command that sets something up first (`export …`, `nvm use`, `source .env`) runs as the
agent wrote it, and so does one whose Metro exits right away. The agent is told the port and the log,
and doesn't start it again, and how to stop it once it's done. Metro keeps running when
the agent's shell or background task ends, until the agent or you stop it, you restart it
from its menu, or you clean up after the agent.
If the port belongs to another project's server, DevDeck picks the next free one and
tells the agent how to point the app at it. If Metro is already running in that folder,
the agent is pointed at it instead. Metro isn't started while dev servers are over their limit or the Mac is short on memory; the call waits like any other.

Under each running device, DevDeck shows which Metro its app loads: for a simulator from
the app's connection to Metro, for an emulator from its `adb reverse` rules, otherwise
from the name the app gives Metro.

## Activity

The **Activity** page lists what DevDeck decided: calls that waited (and why), turned
away, sent to another device or held for your OK, what you did, released claims,
cleanups, Metro events, and limits that went below your setting (or back) for a minute
or more. It's kept for a week in `~/Library/Application Support/DevDeck/activity.jsonl`.

## Notifications

When an agent's call has waited a few seconds, DevDeck posts a notification: which agent,
what it wanted and why it waits ("you're holding iPhone 17", "2 iOS simulators are
running (limit 2)"). **Let Through** runs it now, **Turn Away** tells the agent the
device or the Mac is busy, and a click opens the Leases or Resources page. The
notification goes away when the call runs, and says so if the call gives up. The menu
bar icon shows an hourglass with the number of waiting calls. Turn notifications off in
General → Agent Activity.

## Resources

Heavy work an agent starts waits for room. Each kind has a limit; the one set on the
**Resources** page is the most it allows:

| Kind | Default | Recognized from |
|---|---|---|
| iOS simulators | 2 booted | `simctl boot`, argent `boot-device` |
| Android emulators | 1 running | `emulator -avd`, argent `boot-device` |
| Native builds | 1 | `xcodebuild` (not `test-without-building`: argent's and agent-device's UI-test runners stay up for hours), Gradle builds, `expo run`, `react-native run-*`, `npm run ios`/`android`, local EAS builds |
| Dev servers | 3 | `expo start`, `npm`/`yarn`/`pnpm`/`bun` `start`/`dev`, Vite, Next.js, Storybook, Metro |

Below that, the limit follows what you're doing, worked out when a call arrives:

- **Memory.** Only as many more as fit in the memory macOS can still hand out, after
  keeping 2 GB plus a quarter of what your own apps use (browsers, chat, games; their
  helper processes count, developer tools and agents don't) for them to grow into. A
  simulator counts as 2.5 GB, an emulator 3 GB, a build 4 GB, a dev server 0.75 GB.
- **A game in front** (its App Store category is a games one): one simulator, one emulator
  and one build at a time. Dev servers aren't limited by it.

The Resources page shows your apps' memory and, under a lowered limit, why it's lower.
What's already running is never stopped; only new work waits.

While free memory is below 15% (or macOS reports critical memory pressure), or the Mac
moves more than 16 MB a second in and out of swap for 30 seconds, nothing heavy starts.
How much is swapped out isn't a good sign on its own: pages stay there long after the
pressure is gone.
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

`status` lists leases, the queue, waiting calls, resource use and agent-device claims.

For example:

```bash
echo '{"command": "status"}' | nc -U ~/Library/Application\ Support/DevDeck/broker.sock
```

## Agent sounds

With **Play agent sounds** on, the hooks also report the events that play sounds, and
DevDeck plays them itself (no player or script runs per event). The categories and rules
are peon-ping's:

| Event | Sound | Notification |
|---|---|---|
| Session start (not after compaction) | `session.start`, once per 30 s across sessions | |
| Prompt | `task.acknowledge` (off by default); the third within 10 s plays `user.spam` | clears the session's |
| Turn ended (`Stop`), or idle reminder | `task.complete`; stops within 5 s play once; an idle reminder doesn't repeat one the session played | Done |
| Permission request, question | `input.required` | Needs approval: *tool*, Question pending |
| Shell command failed | `task.error` | |
| Context compaction | `resource.limit` | Compacting context |

Events replayed within 3 s of a session start (`claude -c`) are silent. A notification
isn't shown while the agent's app (its first ancestor that's a regular app) is in front,
and clicking one brings that app forward. Codex only reports `Stop`, so it plays
`task.complete`.

Packs and settings live in `~/Library/Application Support/DevDeck/Sounds` (`Packs/`,
`settings.json`); new packs show up as soon as they're copied there. **Switch from
peon-ping** (or `--sounds on`) copies peon-ping's packs and its volume, pack, category and
notification settings, and removes its hooks (the agent config is kept as
`settings.json.before-devdeck`); peon-ping's own files are left for you to remove.
