# DevDeck companion apps

Small apps DevDeck installs on simulators and emulators to show, on the device itself,
who is driving it: a coding agent (robot) or you (person). They also explain what DevDeck
is, and later can offer controls such as "end work on this device".

- `ios/`: iOS app with a Live Activity, shown in the Dynamic Island and on the lock screen.
- `android/`: Android app that posts a small, silent, dismissible notification.

Both apps are named **DevDeck**, use the DevDeck icon (the Tabler `layout-dashboard` filled
glyph in `#73DB8C` on a dark rounded tile, see `scripts/make-icon.swift`), and have the
id `dev.devdeck.companion`.

## Marker state

DevDeck sends the device's state as JSON:

```json
{ "state": "agent", "holder": "Claude Code", "host": "T3 Code",
  "project": "my-app", "action": "gesture-tap", "since": 1761660000 }
```

- `state`: `agent` (an agent is driving it), `user` (you hold it), or `free` (nobody;
  the marker goes away: on Android the notification is removed, on iOS the Live Activity
  stays alive but shows nothing in the Dynamic Island).
- `holder`: who holds it, e.g. "Claude Code", "Codex" or "You".
- `host`, `project`, `action`: optional details. `since`: Unix seconds when it started.

## iOS (simulators)

iOS only lets an app start a Live Activity while it is in front, so DevDeck starts one
activity right after the simulator boots and from then on only updates it in the
background. The app never comes to the front during work.

The app keeps its files in its data container,
`D=$(xcrun simctl get_app_container <udid> dev.devdeck.companion data)`:

- `$D/Library/DevDeck/state.json`: the marker state (JSON above). DevDeck writes it; the
  app reads it on launch, whenever it comes to the front, and on every wake.
- `$D/Library/DevDeck/status.json`: written by the app on every launch, wake and toggle
  change: `{"activity": "active"|"none", "marker": true|false, "updated": <unix seconds>}`.
  `activity` is `none` when the marker is off, or when iOS has ended the activity (after
  about 8 hours, or when someone dismissed it). If it is `none` while `marker` is `true`,
  start the activity again.

Steps:

- Install: `xcrun simctl install <udid> DevDeckCompanion.app`
- Start (once after boot, before anyone uses the simulator, and again whenever
  `status.json` says `"activity": "none"` with `"marker": true`): write `state.json`, then
  `xcrun simctl launch --terminate-running-process <udid> dev.devdeck.companion --devdeck-start`.
  The app starts or refreshes the activity and sends itself straight back to the home
  screen. `--terminate-running-process` matters: launching an app that is already running
  only brings it to the front and drops the arguments.
- Update (no app switch): write `state.json`, then wake the app with
  `xcrun simctl push <udid> dev.devdeck.companion payload.json` where `payload.json` is
  `{"aps": {"content-available": 1}}`. `simctl push` exits non-zero ("Notification has no
  user visible content"); ignore that, the app is woken all the same. On the simulator the
  push payload never reaches the app (`simctl push` wakes it with a background fetch and
  only turns the payload into a user notification), so the state must be in the file.
- A launch without `--devdeck-start` (someone opening the app) shows the home screen as
  usual. `--devdeck-state '<json>'` is still accepted on launch, as is a `devdeck` key in
  a real APNs push.

Notes:

- The marker toggle in the app is the user's: off ends the activity and ignores states
  (they are still recorded); on starts it again.
- With `free`, the Dynamic Island shows no content, but the system still draws it in its
  compact layout, about 5 pt wider on each side than an idle island. On the lock screen,
  `free` is one quiet line: "DevDeck · Nobody is using this simulator".
- The first time an activity reaches the lock screen, iOS asks "Allow Live Activities from
  DevDeck?" there. The activity shows either way until someone answers. "Don't Allow"
  turns Live Activities off for the app; `status.json` then keeps saying `"activity":
  "none"`, so don't restart the activity again and again (each start briefly brings the
  app to the front).

## Android (emulators)

- Install: `adb -s <serial> install -r devdeck-companion.apk`, then
  `adb -s <serial> shell pm grant dev.devdeck.companion android.permission.POST_NOTIFICATIONS`
- Update (no app switch):
  `adb -s <serial> shell am broadcast -n dev.devdeck.companion/.StateReceiver -f 0x20 --es json '<json>'`
- The broadcast result, printed by `am broadcast`, says what happened:
  - code 1 with data `shown` (notification posted or updated), `hidden` (`free`),
    `disabled` (marker turned off in the app), `dismissed` (the user swiped this hold's
    notification away; it returns when the hold changes), or `blocked` (notifications not
    allowed for the app);
  - code 0 with data `invalid` (missing or malformed JSON).
- Resend the state after install, update or force-stop: the notification is gone after any
  of those.
