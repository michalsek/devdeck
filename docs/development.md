# Development

## Building

```bash
bash scripts/build-app.sh            # builds build/DevDeck.app
bash scripts/build-app.sh --install  # also copies it to ~/Applications and opens it
swift build                          # just the Swift package
swift test                           # unit tests
```

DevDeck needs macOS 26 and must be built with its SDK or newer: apps linked against an
older SDK run in compatibility mode, without the current menu and sidebar materials.

`build-app.sh` also builds the companion apps (`helpers/ios/build.sh` and
`helpers/android/build.sh`) the first time, and bundles them into the app.
`REBUILD_COMPANIONS=1` rebuilds them. DevDeck works without them; it just shows no
device markers. The Android build needs the Android SDK and a JDK 17.

## Signing

macOS keeps folder permissions (Documents and the like) per code signature. Ad hoc
signing changes with every build, so macOS asks again after each one. To keep them, put
your development certificate in `.signing` (git-ignored):

```bash
security find-identity -v -p codesigning   # list your identities
echo 'DEVDECK_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"' > .signing
```

## Launch options

```bash
open ~/Applications/DevDeck.app --args --open dashboard:leases   # open a dashboard page
open ~/Applications/DevDeck.app --args --hooks claude            # install hooks (claude, codex, or none)
open build/DevDeck.app --args --demo --open dashboard:devices    # demo mode
```

Dashboard pages: `devices`, `leases`, `resources`, `servers`, `sounds`, `packs`,
`clients`, `general`.

**Demo mode** fills DevDeck with made-up devices, servers, leases and load, for
screenshots, and changes nothing: no socket for agents, no hook updates, no companion
installs, no device scans. Only one DevDeck runs at a time, so quit the installed one
first. The screenshots in the README come from demo mode.

## Layout

| Folder | What's there |
|---|---|
| `Sources/DevDeck/App` | app entry point, menu bar menu, dashboard window, shared views |
| `Sources/DevDeck/Devices` | device scanning and the Devices page |
| `Sources/DevDeck/Servers` | dev server scanning, stopping and the Dev Servers page |
| `Sources/DevDeck/Agents` | hook events, the broker socket, lease rules (`LeaseBook`), hook installer, device markers, the Leases page |
| `Sources/DevDeck/Pools` | resource limits, the resource monitor and the Resources page |
| `Sources/DevDeck/Sounds` | peon-ping settings |
| `Sources/DevDeck/Demo` | demo mode data |
| `Sources/devdeck-hook` | the helper the agent hooks run |
| `helpers/` | the iOS and Android companion apps |
| `scripts/` | app bundle and icon scripts |

## Credits

The app icon and menu bar icons use filled icons from [Tabler Icons](https://tabler.io/icons)
(MIT).
