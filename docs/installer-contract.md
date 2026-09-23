# huble-install contract v1

`install.sh` is the single implementation of "set up this Mac", "new project",
"open existing project" and "update". Every GUI (the Huble macOS app, the Atlas
plugin's Get Started rows) is a thin client: it collects input, spawns the
installer with environment variables, renders the installer's events and reacts
to the exit code. No client re-implements installer logic.

## Invocation

| how | command |
|---|---|
| human bootstrap (first install, or any time) | `curl -fsSL https://raw.githubusercontent.com/HubleDigital/huble-install/main/install.sh \| bash` |
| human bootstrap with flags | `curl -fsSL …/install.sh \| bash -s -- --contract` |
| client (app / plugin) | `/bin/bash "$HOME/.huble/install.sh"` |

Every successful run saves a copy of itself to `~/.huble/install.sh`, so after
one bootstrap the local copy exists. Clients that find it missing run the curl
bootstrap once (with `HUBLE_VAULT_MODE=skip`) to create it.

### Flags

| flag | effect |
|---|---|
| `--contract` | print the contract line (text) or the `contract` event (json) and exit 0. No side effects. |
| `--version` | print the installer version and exit 0. |
| `--refresh` | re-download `install.sh` from `HUBLE_INSTALL_URL` into `~/.huble/install.sh` and exit. Nothing else. |
| `--check` | **read-only** update report and exit 0 (feature `check`). Never pulls, resets or installs. Fetches `origin/<default branch>` of `~/.huble/platform` and compares; downloads the installer at `HUBLE_INSTALL_URL` to compare versions. Offline → `unknown`, never an error. |

`--check` output (json mode, one event; text mode two lines):

```
{"event":"check","status":"current|available|blocked|missing|unknown",
 "platform":{"state":"ok|missing","behind":3,"ahead":0,"dirty":false,"local":"fdc85a3","remote":"9a1c2e0","branch":"main"},
 "installer":{"status":"current|available|unknown","local":"2.1.0","remote":"2.2.0"}}
```

Rules, so every client shows the same thing: a client shows **"Update platform"
only when** `status == "available"` or `installer.status == "available"`.
`blocked` (dirty or ahead checkout) shows the reason, never the button — the
update path refuses to reset such a checkout anyway. `missing` offers setup.
`unknown` shows nothing or a quiet "couldn't check". Re-check on launch, after
each installer run and on an interval (the Huble app uses 30 minutes), not on
every render. "Update vault" is shown only when the vault's installed plugin
(`<vault>/.obsidian/plugins/atlas-cx/manifest.json` `version`) differs from the
one the platform ships (`~/.huble/platform/huble-pipeline/dist/atlas-cx/manifest.json`),
which is what `cx init` installs; equal means no button.
| `--help` | usage. |

### Environment

| variable | values | meaning |
|---|---|---|
| `HUBLE_OUTPUT` | `text` (default) / `json` | output mode, see below |
| `HUBLE_NONINTERACTIVE` | `1` | never prompt; a missing required value fails with a message. Also implied when there is no controlling terminal. |
| `HUBLE_NO_OPEN` | `1` | do not register/open the vault in Obsidian at the end |
| `HUBLE_VAULT_MODE` | `new` / `clone` / `skip` / `remove` | what to do after tooling is verified. Non-interactive default: `skip` |
| `HUBLE_VAULT_PATH` | absolute vault path | with `remove`: the vault to remove from this Mac (moved to the Trash, forgotten in Obsidian and `installer.json`). **The GitHub repository is never touched.** |
| `HUBLE_FORCE` | `1` | with `remove`: proceed although the vault has uncommitted / unpushed / never-pushed work. Without it such a vault fails with `reason: "unsynced"`; a client asks the user a second time before setting it. |
| `HUBLE_ROLE` | `cx` / `copy` / `seo` / `design` / `dev` / `all` | machine role for the vault. Required (or stored default) for `new`/`clone` |
| `HUBLE_VAULTS_DIR` | absolute path | folder that will contain the vault folder |
| `HUBLE_CLIENT_NAME` | string | with `new`: vault at `$HUBLE_VAULTS_DIR/<name>` |
| `HUBLE_VAULT_REPO` | `owner/name` | with `clone`: vault at `$HUBLE_VAULTS_DIR/<name>` |
| `HUBLE_VAULT_REINIT` | absolute vault path / `no` | with `skip`: re-init that vault's plugin/skills/commands for this machine. Without `HUBLE_NO_OPEN` the vault is then registered and opened in Obsidian — this is how a client "opens a project already on this Mac". The vault's recorded role wins; `HUBLE_ROLE` only fills the gap for a vault that never recorded one. (The plugin has its own update path.) |
| `HUBLE_VAULT_ORG` | org login, default `HubleDigital` | where client vault repos live |
| `HUBLE_VAULT_TOPIC` | default `guerilla-client-vault` | GitHub topic that marks a repo as a client vault |
| `HUBLE_INSTALL_URL` | URL, default raw `main` | where `--refresh` / self-copy download from (use a branch URL for testing) |
| `HUBLE_HOME` | default `~/.huble` | hidden tooling root |
| `HUBLE_PLATFORM_REPO` | default `HubleDigital/huble-platform` | |
| `HUBLE_PLATFORM_UPDATE` | `0` | never `pull`, `reset` or re-point the platform checkout; require that it exists (else `fail`). A client running **inside Obsidian** always passes this — the plugin owns platform updates. `done.platformUpdate` is then `"skipped"`. Feature `platform-update-skip`. |

In every mode the installer never discards local changes in `~/.huble/platform`:
a fast-forward that fails on a dirty checkout warns and reports
`platformUpdate: "failed"` instead of resetting.

Values are passed only through the environment, never interpolated into a
shell string.

### PATH

Clients that do not inherit a login shell (Obsidian, a .app) must pass at least:

```
/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.huble/bin
```

The installer extends its own PATH with `~/.huble/node/bin`,
`~/.huble/npm-global/bin`, `/opt/homebrew/bin` and `/usr/local/bin` when they
exist, and installs `gh`/`node` into `~/.huble` when they are missing. A
client never needs to locate `gh` or `node` itself.

## Non-interactive behaviour

When `HUBLE_NONINTERACTIVE=1` or no terminal is attached:

- no `sudo`, ever: Obsidian goes to `~/Applications` unless `/Applications` is writable; npm globals go to a user prefix.
- Homebrew is never installed; poppler is installed only if `brew` already exists.
- GitHub sign-in uses the device flow: the installer emits a `gh_auth` event with the one-time code and URL, then waits for the user to complete it in the browser. The installer does **not** open the browser in json mode; the client does.
- `HUBLE_VAULT_MODE` defaults to `skip`. `new`/`clone` without name/repo/role fail with a message.

## Output

### text (default)

Human-readable, coloured. First stdout line is always
`huble-install contract v1`. On failure the last stderr line is the reason.

### json (`HUBLE_OUTPUT=json`)

stdout carries **only** newline-delimited JSON events. All output of
subcommands (git, npm, curl, gh) is redirected to stderr, which clients may
show as a raw log. Clients must rely on events, not on stderr, for state.

| event | fields | meaning |
|---|---|---|
| `contract` | `contract` ("v1"), `version`, `features` (array of strings) | always the first line. Clients refuse to continue on an unknown `contract`, and check `features` for the additive capabilities they rely on. Defined: `platform-update-skip`, `remove`, `reinit-open`, `check`. Text mode prints them on a second line `huble-install features: …`. |
| `step` | `message` | a new top-level step started (Checking Node.js, Installing the Huble platform, …) |
| `ok` | `message` | step or sub-step succeeded |
| `note` | `message` | informational |
| `warn` | `message` | non-fatal problem |
| `error` | `message` | serious non-fatal problem (e.g. platform not updated); the run continues |
| `gh_auth` | `code`, `url` | show `code` to the user and open `url`. The installer keeps polling until sign-in completes. |
| `vault` | `path` | the vault this run created, cloned or re-initialised |
| `fail` | `message`, optional `reason` | fatal; exit code 1 follows. `reason` is a machine-readable tag a client may branch on. Defined: `unsynced` (remove refused because work is not on GitHub; retry with `HUBLE_FORCE=1` after a second confirmation). |
| `done` | `vault` (path or ""), `platformUpdated` (bool), `platformUpdate` (`"updated"` / `"skipped"` / `"failed"`) | success; exit code 0 follows |

Example:

```
{"event":"contract","contract":"v1","version":"2.1.0","features":["platform-update-skip","remove","reinit-open","check"]}
{"event":"step","message":"Checking developer tools (git)"}
{"event":"ok","message":"Command Line Tools present"}
{"event":"gh_auth","code":"AB12-CD34","url":"https://github.com/login/device"}
{"event":"vault","path":"/Users/me/Clients/Acme"}
{"event":"done","vault":"/Users/me/Clients/Acme","platformUpdated":true}
```

Exit codes: `0` success, `1` failure. Killing the process (SIGTERM) is the
supported cancel; the installer is idempotent and safe to re-run.

## State file: `~/.huble/installer.json`

```json
{
  "installerVersion": "2.0.0",
  "role": "cx",
  "vaultsDir": "/Users/me/Clients",
  "lastVault": "/Users/me/Clients/Acme"
}
```

- `role` and `vaultsDir` are **defaults the installer offers**; the role recorded
  in a vault's own `<vault>/.huble/machine.json` (written by `huble cx init`) always wins for that vault.
- Clients read this file defensively (missing file, missing keys — machines installed before v1 have none).
- Clients never write it.
- The old `~/.huble/machine.json` (only `lastVault`) is migrated and removed on the first v1 run.

## Client vault discovery

A client vault is a repo in `HUBLE_VAULT_ORG` carrying the topic
`HUBLE_VAULT_TOPIC`. Names are not a signal. Query:

```
gh repo list HubleDigital --topic guerilla-client-vault --json name,description,pushedAt --limit 500
```

Clients prefer `huble vault list --json` (platform CLI, same query) when the
verb exists and fall back to the `gh` query above.

### "Already on this Mac"

A remote vault counts as present locally when a local vault's git `origin`
resolves to the same `owner/name` (case-insensitive, `.git` suffix and
`https://` / `git@github.com:` forms ignored). Folder names are not a signal
(a clone lands in `<vaultsDir>/<repo-name>`, hand-made vaults are named after
the client). Both clients (app, plugin) use this rule; the Huble app then
offers to open the local copy instead of cloning again.

## Opening a vault in Obsidian

- `new` / `clone` without `HUBLE_NO_OPEN`: the installer registers the vault
  with Obsidian (quit → write `obsidian.json` → relaunch) and opens it. Clients
  that are not Obsidian should leave `HUBLE_NO_OPEN` unset and let the installer do it.
- an already-registered vault: `open "obsidian://open?path=<url-encoded absolute path>"`.
