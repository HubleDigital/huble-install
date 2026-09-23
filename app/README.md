# Huble.app

Native macOS front end for the Huble installer. The team never opens a
terminal: set up the Mac, create a project, open an existing client vault from
GitHub, update the platform — all from one window.

## Build

```bash
cd app
./scripts/build-app.sh          # → app/build/Huble.app
open build/Huble.app
```

Needs Xcode (Swift 5.9+; built with Xcode 27). No third-party dependencies, no
`.xcodeproj` — it is a plain SwiftPM package.

## Signing

The default build is **ad-hoc signed**: it runs on the Mac that built it, but
Gatekeeper blocks it on any other Mac (macOS 15+ removed the right-click →
Open bypass for unnotarized apps). Distribution needs an Apple Developer ID:

```bash
# once: store the notarytool credentials
xcrun notarytool store-credentials huble-notary --apple-id you@hubledigital.com --team-id TEAMID

./scripts/build-app.sh --sign "Developer ID Application: Huble Digital (TEAMID)" --notarize huble-notary
# → app/build/Huble.app (stapled) and app/build/Huble.zip to hand out
```

## Architecture

The app is a thin client over `docs/installer-contract.md`. It never
implements installer logic:

- `Installer/InstallerRunner.swift` spawns `/bin/bash ~/.huble/install.sh`
  with `HUBLE_OUTPUT=json`, `HUBLE_NONINTERACTIVE=1` and the per-action
  `HUBLE_*` variables, and turns the NDJSON events into the progress sheet.
  User input reaches the installer only through environment variables.
- `Installer/Bootstrap.swift` downloads `install.sh` once when `~/.huble/`
  has no copy yet (first run on a Mac); afterwards the installer keeps its own
  copy fresh.
- `State/` reads `~/.huble/installer.json` (defaults), scans the vaults
  folder, and lists client vault repos (`huble vault list --json`, falling
  back to `gh repo list HubleDigital --topic guerilla-client-vault`).
- `Views/` — `SetupView` (first run), `MainView` (vault list + footer),
  `NewProjectSheet`, `OpenExistingSheet`, `ProgressSheet` (steps, GitHub
  device-code card, log, cancel).

GitHub sign-in: the installer runs `gh auth login --web` without a terminal,
which prints a one-time code and the device URL. The app shows the code and
opens the URL; the installer keeps polling until the sign-in completes.
