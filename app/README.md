# Huble.app

Native macOS front end for the Huble installer. The team never opens a
terminal: set up the Mac, create a project, open an existing client vault from
GitHub, update the platform — all from one window.

## Build

```bash
cd app
./scripts/build-app.sh --version 0.1.1   # → app/build/Huble.app (universal) + build/Huble-0.1.1-universal.zip + sha256
open build/Huble.app
```

`--version` is required (or `HUBLE_APP_VERSION`); it goes into Info.plist and
the zip name. The binary is universal (arm64 + x86_64). Needs Xcode (Swift
5.9+; built with Xcode 27). No third-party dependencies, no `.xcodeproj` — it
is a plain SwiftPM package.

Release: build, then `gh release create app-v<version> build/Huble-<version>-universal.zip`.

## Signing

The default build is **ad-hoc signed**: it runs on the Mac that built it, but
Gatekeeper blocks it on any other Mac (macOS 15+ removed the right-click →
Open bypass for unnotarized apps). Distribution needs an Apple Developer ID:

```bash
# once: store the notarytool credentials
xcrun notarytool store-credentials huble-notary --apple-id you@hubledigital.com --team-id TEAMID

./scripts/build-app.sh --version 0.2.0 --sign "Developer ID Application: Huble Digital (TEAMID)" --notarize huble-notary
# → app/build/Huble.app (stapled) and app/build/Huble-0.2.0-universal.zip to hand out
```

## Architecture

The app is a thin client over `docs/installer-contract.md`. It never
implements installer logic:

- `Installer/InstallerRunner.swift` spawns `/bin/bash ~/.huble/install.sh`
  with `HUBLE_OUTPUT=json`, `HUBLE_NONINTERACTIVE=1` and the per-action
  `HUBLE_*` variables, and turns the NDJSON events into the progress sheet.
  User input reaches the installer only through environment variables.
- `Installer/Bootstrap.swift` downloads `install.sh` when `~/.huble/` has no
  copy yet; afterwards the installer keeps its own copy fresh. "Fresh Mac" is
  decided by the platform checkout (`~/.huble/platform`), never by that file:
  a Mac set up before contract v1 has the platform but no saved installer,
  and gets the installer fetched silently in the background instead.
- `Installer/UpdateCheck.swift` runs `install.sh --check` (read-only) so
  "Update platform" only appears when an update exists.
- `State/` reads `~/.huble/installer.json` (defaults), scans the vaults
  folder plus Obsidian's own vault list, and lists client vault repos
  (`huble vault list --json`, falling back to
  `gh repo list HubleDigital --topic guerilla-client-vault`).
- `Views/` — `SetupView` (no platform yet), `MainView` (vault list + footer),
  `NewProjectSheet`, `CloneProjectSheet` (GitHub), `OpenProjectSheet` (a
  folder on this Mac), `ProgressSheet` (steps, GitHub device-code card, log,
  cancel).

GitHub sign-in: the installer runs `gh auth login --web` without a terminal,
which prints a one-time code and the device URL. The app shows the code and
opens the URL; the installer keeps polling until the sign-in completes.
