#!/bin/bash
# Huble platform installer - sets up everything a team member needs:
#   Obsidian, Node, GitHub access, the Huble platform, the Claude agent CLI,
#   and a client vault with the Atlas plugin preconfigured for your role.
#
# Usage (one line, run it again any time to update):
#   curl -fsSL https://raw.githubusercontent.com/HubleDigital/huble-install/main/install.sh | bash
#
# Vaults are created in the folder you run the installer from (any drive);
# tooling hides in ~/.huble. Every successful run also saves a copy of this
# script to ~/.huble/install.sh so GUI clients (the Huble app, the Atlas
# plugin) can run it locally without a terminal.
#
# This script is the single implementation of "set up this Mac", "new
# project", "open existing project" and "update". GUI clients only collect
# input and drive it through the environment variables below - the full
# contract (events, exit codes, state file) is docs/installer-contract.md.
#
# Flags:  --contract | --version | --refresh | --help
#
# Non-interactive overrides:
#   HUBLE_OUTPUT=text|json        json: one event per stdout line (contract)
#   HUBLE_NONINTERACTIVE=1        never prompt (implied without a terminal)
#   HUBLE_HOME=~/.huble           hidden tooling root (platform/node/npm/gh)
#   HUBLE_VAULTS_DIR=/path        where vaults go (default: launch folder, then
#                                 the folder remembered in installer.json)
#   HUBLE_PLATFORM_REPO=HubleDigital/huble-platform
#   HUBLE_PLATFORM_UPDATE=0       never pull/reset the platform checkout (a
#                                 client inside Obsidian owns platform updates)
#   HUBLE_ROLE=cx|copy|seo|design|dev|all    skip the role prompt
#                 (all = orchestrator/test machines, not shown in the menu)
#   HUBLE_VAULT_MODE=new|clone|skip|remove
#   HUBLE_VAULT_REINIT=/path|no   with skip: re-init that vault (or don't ask)
#   HUBLE_VAULT_PATH=/path        with remove: the vault to move to the Trash
#   HUBLE_FORCE=1                 with remove: even when it has unsynced changes
#   HUBLE_CLIENT_NAME="Client"    with HUBLE_VAULT_MODE=new
#   HUBLE_VAULT_REPO=owner/repo   with HUBLE_VAULT_MODE=clone
#   HUBLE_VAULT_ORG=HubleDigital  org whose topic-tagged repos are client vaults
#   HUBLE_VAULT_TOPIC=guerilla-client-vault
#   HUBLE_INSTALL_URL=...         where --refresh / the self-copy download from
#   HUBLE_NO_OPEN=1               don't open Obsidian at the end
set -euo pipefail

INSTALLER_VERSION="2.4.0"
CONTRACT_VERSION="v1"
# Additive capabilities within contract v1. A client that needs one checks
# for it in the contract event / line instead of guessing from the version.
#   platform-update-skip  HUBLE_PLATFORM_UPDATE=0 honoured
#   remove                HUBLE_VAULT_MODE=remove (+ HUBLE_FORCE, fail.reason)
#   reinit-open           a re-initialised vault is opened in Obsidian unless HUBLE_NO_OPEN
#   check                 --check: read-only "is an update available" report
CONTRACT_FEATURES="platform-update-skip remove reinit-open check"
INSTALL_URL="${HUBLE_INSTALL_URL:-https://raw.githubusercontent.com/HubleDigital/huble-install/main/install.sh}"

# Tooling lives hidden in ~/.huble (platform checkout, user-level node/npm/gh).
HUBLE_HOME="${HUBLE_HOME:-$HOME/.huble}"
INSTALLER_STATE="$HUBLE_HOME/installer.json"

# ---------------------------------------------------------------- Output + prompts
# Two output modes. text: coloured, human. json (HUBLE_OUTPUT=json): stdout
# carries ONLY newline-delimited events for a GUI client; everything the
# subcommands print (git, npm, curl, gh) is redirected to stderr as a raw log.
# fd 3 is always "the event channel" so helpers never care which mode is on.
OUTPUT_MODE="${HUBLE_OUTPUT:-text}"
case "$OUTPUT_MODE" in text|json) ;; *) OUTPUT_MODE="text" ;; esac
exec 3>&1
JSON_OUT=false
if [ "$OUTPUT_MODE" = "json" ]; then JSON_OUT=true; exec 1>&2; fi

# Prompts need a terminal. No terminal, or HUBLE_NONINTERACTIVE=1, means a
# GUI client is driving: every answer must come from the environment, and
# nothing may block on sudo or a password.
INTERACTIVE=true
if [ -n "${HUBLE_NONINTERACTIVE:-}" ] || ! ( : < /dev/tty ) 2>/dev/null; then INTERACTIVE=false; fi

json_escape() { # json_escape "text" -> escaped for a JSON string (no quotes)
  printf '%s' "$1" | tr -d '\000-\010\013-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}
emit() { # emit event key value [key value ...] - one JSON event line on fd 3
  local ev="$1" out; shift
  out="{\"event\":\"$ev\""
  while [ "$#" -ge 2 ]; do
    case "$2" in
      true|false) out="$out,\"$1\":$2" ;;
      *) out="$out,\"$1\":\"$(json_escape "$2")\"" ;;
    esac
    shift 2
  done
  printf '%s}\n' "$out" >&3
}

CURRENT_STEP=""
FAIL_EMITTED=false
bold()  { $JSON_OUT || printf '\033[1m%s\033[0m\n' "$*" >&3; }
step()  { CURRENT_STEP="$*"; if $JSON_OUT; then emit step message "$*"; else printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*" >&3; fi; }
ok()    { if $JSON_OUT; then emit ok message "$*";    else printf '\033[32m  OK %s\033[0m\n' "$*" >&3; fi; }
warn()  { if $JSON_OUT; then emit warn message "$*";  else printf '\033[33m  ! %s\033[0m\n' "$*" >&3; fi; }
note()  { if $JSON_OUT; then emit note message "$*";  else printf '  - %s\n' "$*" >&3; fi; }
err()   { if $JSON_OUT; then emit error message "$*"; else printf '\033[31m  X %s\033[0m\n' "$*" >&3; fi; } # loud, non-fatal
FAIL_REASON=""   # machine-readable tag a client can branch on (e.g. unsynced)
fail()  {
  FAIL_EMITTED=true
  if $JSON_OUT; then
    if [ -n "$FAIL_REASON" ]; then emit fail message "$*" reason "$FAIL_REASON"; else emit fail message "$*"; fi
  fi
  printf '\033[31m  X %s\033[0m\n' "$*" >&2
  exit 1
}
# A command dying under set -e never reaches fail(): tell the client which
# step broke instead of leaving it with a bare exit code.
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && ! $FAIL_EMITTED; then
    FAIL_EMITTED=true
    $JSON_OUT && emit fail message "Step '${CURRENT_STEP:-startup}' failed (exit $rc) - see the log above."
    printf '\033[31m  X Step %s failed (exit %s) - see the output above.\033[0m\n' "'${CURRENT_STEP:-startup}'" "$rc" >&2
  fi
}
trap on_exit EXIT

# Reading prompts must come from the terminal even when the script itself is
# piped in via curl | bash. Non-interactive: the default is the answer, and a
# prompt without a default is a missing value the client forgot to pass.
ask() { # ask "Prompt" varname [default] [ENV_HINT]
  local prompt="$1" var="$2" default="${3:-}" hint="${4:-}" answer
  if ! $INTERACTIVE; then
    if [ -n "$default" ]; then eval "$var=\"\$default\""; return 0; fi
    fail "Non-interactive run: no value for '$(printf '%s' "$prompt" | sed 's/^ *//')'${hint:+ - set $hint}."
  fi
  if [ -n "$default" ]; then prompt="$prompt [$default]"; fi
  printf '%s: ' "$prompt" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=""
  if [ -z "$answer" ]; then answer="$default"; fi
  eval "$var=\"\$answer\""
}

# curl progress bars are terminal-only; a GUI client just wants silence.
if $INTERACTIVE && ! $JSON_OUT; then CURL_PROGRESS="--progress-bar"; else CURL_PROGRESS="-sS"; fi

# ---------------------------------------------------------------- Flags
usage() {
  cat >&3 <<EOF
Huble installer $INSTALLER_VERSION (contract $CONTRACT_VERSION)

  curl -fsSL $INSTALL_URL | bash            set up / update this Mac
  bash ~/.huble/install.sh [--flag]         same, from the saved local copy

  --contract   print the contract version and exit
  --version    print the installer version and exit
  --check      report whether a platform / installer update is available (read-only) and exit
  --refresh    re-download install.sh into $HUBLE_HOME/install.sh and exit
  --help       this text

Environment overrides: see the header of this script or docs/installer-contract.md.
EOF
}
refresh_self() { # download the current installer into $HUBLE_HOME/install.sh
  local tmp="$HUBLE_HOME/install.sh.tmp"
  mkdir -p "$HUBLE_HOME"
  if curl -fsSL "$INSTALL_URL" -o "$tmp" && grep -q '^INSTALLER_VERSION=' "$tmp"; then
    mv -f "$tmp" "$HUBLE_HOME/install.sh" && chmod +x "$HUBLE_HOME/install.sh"
    return 0
  fi
  rm -f "$tmp"
  return 1
}
print_contract() {
  if $JSON_OUT; then
    local list="" f
    for f in $CONTRACT_FEATURES; do list="$list${list:+,}\"$f\""; done
    printf '{"event":"contract","contract":"%s","version":"%s","features":[%s]}\n' "$CONTRACT_VERSION" "$INSTALLER_VERSION" "$list" >&3
  else
    printf 'huble-install contract %s\n' "$CONTRACT_VERSION" >&3
    printf 'huble-install features: %s\n' "$CONTRACT_FEATURES" >&3
  fi
}
# Read-only update check for GUI clients: they show "Update platform" only
# when this says something is behind. Never pulls, resets or installs; a
# network failure is reported as "unknown", not as an error (exit 0 always).
# A dirty or ahead checkout is "blocked", never "available" - the update
# path would refuse to reset it anyway.
check_updates() {
  local pdir="$HUBLE_HOME/platform" pstate="missing" branch="" fetched=false
  local behind=null ahead=null dirty=false lrev="" rrev="" iremote=""
  if [ -d "$pdir/.git" ]; then
    pstate="ok"
    branch="$(git -C "$pdir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    [ -n "$branch" ] || branch="main"
    lrev="$(git -C "$pdir" rev-parse --short HEAD 2>/dev/null || true)"
    [ -n "$(git -C "$pdir" status --porcelain 2>/dev/null)" ] && dirty=true
    if git -C "$pdir" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 fetch --quiet origin "$branch" >/dev/null 2>&1; then
      fetched=true
      rrev="$(git -C "$pdir" rev-parse --short "origin/$branch" 2>/dev/null || true)"
      behind="$(git -C "$pdir" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo null)"
      ahead="$(git -C "$pdir" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo null)"
    fi
  fi
  iremote="$(curl -fsSL --max-time 20 "$INSTALL_URL" 2>/dev/null | sed -n 's/^INSTALLER_VERSION="\([^"]*\)".*/\1/p' | head -1)"
  # One summary word so a client does not have to re-derive the rules.
  local status="unknown"
  if [ "$pstate" = "missing" ]; then status="missing"
  elif $dirty || { [ "$ahead" != null ] && [ "$ahead" -gt 0 ]; }; then status="blocked"
  elif $fetched && [ "$behind" != null ]; then
    if [ "$behind" -gt 0 ]; then status="available"; else status="current"; fi
  fi
  local istatus="unknown"
  if [ -n "$iremote" ]; then
    if [ "$iremote" = "$INSTALLER_VERSION" ]; then istatus="current"; else istatus="available"; fi
  fi
  if $JSON_OUT; then
    printf '{"event":"check","status":"%s","platform":{"state":"%s","behind":%s,"ahead":%s,"dirty":%s,"local":"%s","remote":"%s","branch":"%s"},"installer":{"status":"%s","local":"%s","remote":"%s"}}\n' \
      "$status" "$pstate" "$behind" "$ahead" "$dirty" "$(json_escape "$lrev")" "$(json_escape "$rrev")" "$(json_escape "$branch")" \
      "$istatus" "$INSTALLER_VERSION" "$(json_escape "$iremote")" >&3
  else
    printf 'platform: %s (local %s, remote %s, behind %s, ahead %s%s)\n' "$status" "${lrev:-?}" "${rrev:-?}" "$behind" "$ahead" "$($dirty && printf ', local changes')" >&3
    printf 'installer: %s (local %s, remote %s)\n' "$istatus" "$INSTALLER_VERSION" "${iremote:-?}" >&3
  fi
}
# The contract line is ALWAYS the first thing on stdout - a client checks it
# before trusting anything else, flags included (--version is the one
# exception: its whole output is the bare version).
case " $* " in *" --version "*) ;; *) print_contract ;; esac
for arg in "$@"; do
  case "$arg" in
    --contract) exit 0 ;;
    --check) check_updates; exit 0 ;;
    --version) printf '%s\n' "$INSTALLER_VERSION" >&3; exit 0 ;;
    --refresh)
      $JSON_OUT && emit step message "Updating the installer"
      refresh_self || fail "Could not download the installer from $INSTALL_URL."
      ok "Installer saved to $HUBLE_HOME/install.sh ($(sed -n 's/^INSTALLER_VERSION="\([^"]*\)".*/\1/p' "$HUBLE_HOME/install.sh" | head -1))"
      $JSON_OUT && emit done vault "" platformUpdated false platformUpdate "skipped"
      exit 0 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown flag '$arg' (try --help)." ;;
  esac
done


# One-time migration from the old visible ~/Huble layout: move the tooling
# dirs into ~/.huble, repoint vault pipelineRoot configs and the .zprofile
# PATH block, and leave ~/Huble holding only vaults (delete it when empty).
migrate_legacy_home() {
  local old="$HOME/Huble"
  [ "$HUBLE_HOME" = "$HOME/.huble" ] || return 0
  # Config rewrites run UNCONDITIONALLY - a stale npm prefix or PATH block can
  # outlive the old folder (and a stale prefix resurrects it on any npm -g).
  if [ -f "$HOME/.npmrc" ] && grep -qs "$old" "$HOME/.npmrc"; then
    sed -i '' "s|$old/|$HUBLE_HOME/|g" "$HOME/.npmrc" 2>/dev/null || true
    note "Repointed npm prefix in ~/.npmrc"
  fi
  if [ -f "$HOME/.zprofile" ] && grep -qs "$old" "$HOME/.zprofile"; then
    sed -i '' "s|$old/|$HUBLE_HOME/|g" "$HOME/.zprofile" 2>/dev/null || true
    note "Repointed PATH block in ~/.zprofile"
  fi
  [ -d "$old" ] || return 0
  # Tooling dirs found under the old layout move over (idempotent - also
  # catches stragglers like an npm-global recreated by a stale .npmrc).
  local moved=false
  mkdir -p "$HUBLE_HOME"
  for d in platform node npm-global bin; do
    if [ -e "$old/$d" ] && [ ! -e "$HUBLE_HOME/$d" ]; then
      $moved || note "Migrating tooling from $old to $HUBLE_HOME..."
      moved=true
      mv "$old/$d" "$HUBLE_HOME/$d"
    fi
  done
  # A leftover dir that exists on BOTH sides (recreated after migration) is
  # tooling debris - the hidden side wins.
  for d in npm-global bin; do
    [ -e "$old/$d" ] && [ -e "$HUBLE_HOME/$d" ] && rm -rf "$old/$d"
  done
  # Repoint pipelineRoot in any vaults still living under the old layout.
  if [ -d "$old/vaults" ] && command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs"), path = require("path");
      const [oldHome, newHome, vaultsDir] = process.argv.slice(1);
      for (const name of fs.readdirSync(vaultsDir)) {
        const cfgPath = path.join(vaultsDir, name, "project-config.json");
        if (!fs.existsSync(cfgPath)) continue;
        const raw = fs.readFileSync(cfgPath, "utf8");
        const next = raw.split(oldHome + "/platform").join(newHome + "/platform");
        if (next !== raw) { fs.writeFileSync(cfgPath, next); console.log("  - repointed", cfgPath); }
      }
    ' "$old" "$HUBLE_HOME" "$old/vaults"
  fi
  rmdir "$old" 2>/dev/null || true
}
migrate_legacy_home
PLATFORM_REPO="${HUBLE_PLATFORM_REPO:-HubleDigital/huble-platform}"
PLATFORM_DIR="$HUBLE_HOME/platform"
# Vaults are USER-VISIBLE work. Precedence: HUBLE_VAULTS_DIR, then the folder
# the installer was launched from when that is a deliberate choice (not $HOME,
# not /), then the folder remembered in installer.json, then $HOME. The
# installer.json lookup needs Node, so the final value is resolved at the
# vault step (resolve_vaults_dir), not here.
LAUNCH_DIR="$(pwd)"
if [ "$LAUNCH_DIR" = "/" ] || [ ! -w "$LAUNCH_DIR" ]; then LAUNCH_DIR="$HOME"; fi
VAULTS_DIR="${HUBLE_VAULTS_DIR:-$LAUNCH_DIR}"
MIN_NODE_MAJOR=24   # the dex task CLI (@zeeg/dex) requires Node >= 24
VAULT_ORG="${HUBLE_VAULT_ORG:-HubleDigital}"
VAULT_TOPIC="${HUBLE_VAULT_TOPIC:-guerilla-client-vault}"

clean_path() { # normalize a pasted/drag-and-dropped filesystem path
  # Terminal drag-and-drop inserts shell escapes (My\ Shared\ Files) and
  # users paste quoted paths — read -r keeps all of that literally, so the
  # folder check fails on a perfectly good path. Strip surrounding quotes,
  # drop backslash escapes, expand a leading ~, trim whitespace.
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
  case "$p" in
    \"*\") p="${p%\"}"; p="${p#\"}" ;;
    \'*\') p="${p%\'}"; p="${p#\'}" ;;
  esac
  p="$(printf '%s' "$p" | sed 's/\\\(.\)/\1/g')"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  printf '%s' "$p"
}

valid_role() { case "$1" in cx|copy|seo|design|dev|all) return 0 ;; *) return 1 ;; esac; }
ask_role() { # ask_role varname [default] - prompt until a valid role
  # Interactive runs default to cx; a GUI client must pass HUBLE_ROLE (or
  # have a stored default) - never silently pick a role for it.
  local r default="${2:-}"
  if $INTERACTIVE && [ -z "$default" ]; then default="cx"; fi
  while :; do
    ask "  Your role (cx / copy / seo / design / dev, or all)" r "$default" HUBLE_ROLE
    if valid_role "$r"; then break; fi
    warn "Unknown role '$r' - choose one of: cx / copy / seo / design / dev / all"
  done
  eval "$1=\"\$r\""
}

# Tiny JSON helpers for machine.json files (~/.huble remembers the last vault;
# a vault's .huble remembers its role). Only called after the Node step.
json_read() { # json_read file key -> stdout (empty if absent/unreadable)
  node -e '
    try {
      const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]];
      if (typeof v === "string") process.stdout.write(v);
    } catch {}
  ' "$1" "$2" 2>/dev/null || true
}
json_write() { # json_write file key value - merge one key, keep the rest
  node -e '
    const fs = require("fs"), path = require("path");
    const [file, key, value] = process.argv.slice(1);
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
    cfg[key] = value;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
  ' "$1" "$2" "$3"
}

[ "$(uname -s)" = "Darwin" ] || fail "This installer supports macOS only (for now)."
ARCH="$(uname -m)"   # arm64 or x86_64

# Non-admin users (no sudo) get user-level installs: ~/Applications for apps,
# $HUBLE_HOME/node and $HUBLE_HOME/npm-global for the toolchain. Never prompt
# for a password a user does not have.
IS_ADMIN=false
if groups 2>/dev/null | tr ' ' '\n' | grep -qx admin; then IS_ADMIN=true; fi

# Make user-level tool locations visible to this run AND future shells. A GUI
# client (Obsidian, the Huble app) passes a bare PATH without the login
# profile, so Homebrew's dirs are appended too - AFTER ours, so a brew node
# never shadows the toolchain the installer manages.
export PATH="$HUBLE_HOME/bin:$HUBLE_HOME/node/bin:$HUBLE_HOME/npm-global/bin:$PATH"
for extra in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$extra" ] || continue
  case ":$PATH:" in *":$extra:"*) ;; *) PATH="$PATH:$extra" ;; esac
done
export PATH
ensure_path_persisted() {
  # ~/.zprofile is the primary (macOS ships zsh), but a customized ~/.zshrc
  # that resets PATH runs AFTER it and silently drops our block - seen in the
  # field as `command not found: huble` in every new terminal. Append to
  # ~/.zshrc too: it runs last for interactive shells (login or not), so the
  # block survives PATH-resetting dotfiles. ~/.bash_profile is appended only
  # when it already exists - creating one would change bash's startup file
  # resolution (~/.bash_profile shadows ~/.profile).
  local marker="# huble-installer PATH" profile
  for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    if [ "$profile" = "$HOME/.bash_profile" ] && [ ! -f "$profile" ]; then continue; fi
    if ! grep -qs "$marker" "$profile" 2>/dev/null; then
      printf '\n%s\nexport PATH="%s/bin:%s/node/bin:%s/npm-global/bin:$PATH"\n' \
        "$marker" "$HUBLE_HOME" "$HUBLE_HOME" "$HUBLE_HOME" >> "$profile"
    fi
  done
}

bold ""
bold "Huble platform installer $INSTALLER_VERSION"
note "Tooling (hidden): $HUBLE_HOME"
mkdir -p "$HUBLE_HOME"
# Persist the PATH block unconditionally - brew-based installs never hit the
# fallback branches that used to be the only callers, so `huble` (and any
# user-level tooling) was missing from new terminals on those machines.
ensure_path_persisted

# ---------------------------------------------------------------- Xcode CLT / git
step "Checking developer tools (git)"
if xcode-select -p >/dev/null 2>&1; then
  ok "Command Line Tools present"
else
  note "Triggering the macOS Command Line Tools install dialog - click Install, then re-run this script."
  xcode-select --install >/dev/null 2>&1 || true
  fail "Re-run the installer once the Command Line Tools have finished installing."
fi

# ---------------------------------------------------------------- Obsidian
step "Checking Obsidian"
if [ -d "/Applications/Obsidian.app" ] || [ -d "$HOME/Applications/Obsidian.app" ]; then
  ok "Obsidian installed"
else
  note "Downloading the latest Obsidian..."
  # Take the .dmg asset URL straight from the release metadata - asset naming
  # has changed before (no more -universal suffix), so never construct it.
  OBS_URL="$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
    | sed -n 's/.*"browser_download_url": *"\([^"]*\.dmg\)".*/\1/p' | head -1)"
  [ -n "$OBS_URL" ] || fail "Could not find the Obsidian .dmg download URL."
  OBS_DMG="/tmp/Obsidian-latest.dmg"
  curl -fL $CURL_PROGRESS -o "$OBS_DMG" "$OBS_URL"
  # Admins install system-wide; everyone else gets ~/Applications (works the
  # same, no password needed). A GUI client cannot answer a sudo prompt, so
  # non-interactive runs only use /Applications when it is writable as-is.
  if [ -w /Applications ] || { $IS_ADMIN && $INTERACTIVE; }; then APP_DIR="/Applications"; else APP_DIR="$HOME/Applications"; fi
  mkdir -p "$APP_DIR"
  note "Installing to $APP_DIR..."
  MOUNT_DIR="$(hdiutil attach "$OBS_DMG" -nobrowse -readonly | sed -n 's/.*\(\/Volumes\/.*\)/\1/p' | tail -1)"
  if ! cp -R "$MOUNT_DIR/Obsidian.app" "$APP_DIR/" 2>/dev/null; then
    if $IS_ADMIN && $INTERACTIVE; then
      note "Needs your password to write to $APP_DIR..."
      sudo cp -R "$MOUNT_DIR/Obsidian.app" "$APP_DIR/"
    else
      hdiutil detach "$MOUNT_DIR" -quiet || true
      fail "Could not write to $APP_DIR."
    fi
  fi
  hdiutil detach "$MOUNT_DIR" -quiet
  rm -f "$OBS_DMG"
  ok "Obsidian installed in $APP_DIR"
fi

# ---------------------------------------------------------------- Node
step "Checking Node.js (>= $MIN_NODE_MAJOR)"
node_ok=false
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$NODE_MAJOR" -ge "$MIN_NODE_MAJOR" ]; then
    node_ok=true
  else
    note "Node $(node --version) is too old - the dex CLI needs Node >= $MIN_NODE_MAJOR. Upgrading..."
  fi
fi
if $node_ok; then
  ok "Node $(node --version)"
else
  case "$ARCH" in
    arm64) NODE_ARCH="arm64" ;;
    *)     NODE_ARCH="x64" ;;
  esac
  if command -v brew >/dev/null 2>&1; then
    note "Installing Node via Homebrew..."
    # An outdated brew node makes `brew install` error out with an "already
    # installed, run brew upgrade" hint - follow that hint automatically.
    # stdin comes from /dev/null: under `curl | bash` OUR stdin IS the script
    # pipe, and a child that reads it eats the rest of the script (the parent
    # then exits silently at "EOF"). Same rule for every brew/npm child below.
    if ! brew install node </dev/null >/dev/null 2>&1; then
      brew upgrade node </dev/null >/dev/null 2>&1 \
        || warn "Homebrew could not install Node - checking what resolves anyway..."
    fi
  else
    # Official tarball into $HUBLE_HOME/node — works with or without admin
    # rights, no password, and keeps tooling hidden like everything else.
    # (The old admin path downloaded node-<ver>-<arch>.pkg, which does not
    # exist on nodejs.org — the macOS pkg is universal, no arch suffix — so
    # every brew-less admin machine 404'd and aborted here.)
    NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | sed -n 's/.*"version": *"\(v24[^"]*\)".*/\1/p' | head -1)"
    if [ -z "$NODE_VER" ]; then
      fail "Could not determine the latest Node 24 version from nodejs.org (network/proxy issue?). Install Node $MIN_NODE_MAJOR+ manually (https://nodejs.org) and re-run this installer."
    fi
    note "Installing Node $NODE_VER into $HUBLE_HOME/node (no password needed)..."
    NODE_TAR="/tmp/node-$NODE_VER.tar.gz"
    curl -fL $CURL_PROGRESS -o "$NODE_TAR" "https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-darwin-$NODE_ARCH.tar.gz"
    rm -rf "$HUBLE_HOME/node"
    mkdir -p "$HUBLE_HOME/node"
    tar -xzf "$NODE_TAR" -C "$HUBLE_HOME/node" --strip-components 1
    rm -f "$NODE_TAR"
    ensure_path_persisted
  fi
  # An older node earlier in PATH (e.g. a pinned node@18 keg) can shadow the
  # fresh install - verify what actually resolves before moving on.
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "$NODE_MAJOR" -lt "$MIN_NODE_MAJOR" ]; then
    fail "Node $(node --version 2>/dev/null || echo '?') still resolves after the install - an older Node earlier in your PATH is shadowing it. The dex CLI needs Node >= $MIN_NODE_MAJOR: remove or upgrade the old Node (https://nodejs.org) and re-run this installer."
  fi
  ok "Node $(node --version) installed"
fi

# ---------------------------------------------------------------- GitHub CLI + auth
step "Checking GitHub access"
if ! command -v gh >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    note "Installing GitHub CLI via Homebrew..."
    brew install gh </dev/null >/dev/null \
      || fail "Homebrew could not install the GitHub CLI (required). Run: brew install gh  - then re-run this installer."
  else
    note "Installing GitHub CLI..."
    GH_TAG="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
    GH_VER="${GH_TAG#v}"
    case "$ARCH" in
      arm64) GH_ARCH="macOS_arm64" ;;
      *)     GH_ARCH="macOS_amd64" ;;
    esac
    GH_ZIP="/tmp/gh.zip"
    curl -fL $CURL_PROGRESS -o "$GH_ZIP" \
      "https://github.com/cli/cli/releases/download/$GH_TAG/gh_${GH_VER}_${GH_ARCH}.zip"
    mkdir -p "$HUBLE_HOME/bin"
    ditto -xk "$GH_ZIP" /tmp/gh-extract
    cp "/tmp/gh-extract/gh_${GH_VER}_${GH_ARCH}/bin/gh" "$HUBLE_HOME/bin/gh"
    chmod +x "$HUBLE_HOME/bin/gh"
    rm -rf "$GH_ZIP" /tmp/gh-extract
    ensure_path_persisted
  fi
fi
ok "GitHub CLI present"
# Device-code sign-in. With a terminal gh drives it itself. Without one, gh
# still prints the one-time code + URL and polls (verified: gh 2.96 with
# stdin at /dev/null) - relay them as a gh_auth event so the GUI client can
# show the code and open the browser, and keep gh running until it's done.
gh_login() {
  if $INTERACTIVE; then
    gh auth login --hostname github.com --git-protocol https --web < /dev/tty
    return
  fi
  local line code="" url="" sent=false
  set +e
  gh auth login --hostname github.com --git-protocol https --web </dev/null 2>&1 \
    | while IFS= read -r line; do
        printf '%s\n' "$line" >&2
        case "$line" in
          *one-time\ code:*) code="$(printf '%s' "$line" | sed -n 's/.*one-time code: *\([A-Z0-9-]*\).*/\1/p')" ;;
          *https://github.com/login/device*) url="$(printf '%s' "$line" | sed -n 's/.*\(https:\/\/github\.com\/login\/device[^ ]*\).*/\1/p')" ;;
        esac
        if ! $sent && [ -n "$code" ] && [ -n "$url" ]; then
          sent=true
          if $JSON_OUT; then emit gh_auth code "$code" url "$url"; else
            note "GitHub sign-in: open $url and enter the code $code"
          fi
        fi
      done
  local rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || fail "GitHub sign-in did not complete (gh exit $rc). Re-run to try again."
}
if gh auth status >/dev/null 2>&1; then
  ok "GitHub authenticated as $(gh api user --jq .login 2>/dev/null || echo '?')"
else
  note "Sign in to GitHub - a browser window will guide you (device code flow)."
  gh_login
fi

# A valid login is not enough: the wrong account (personal vs work) passes
# auth but dies later at the platform/vault clone with a cryptic GraphQL
# "Could not resolve to a Repository" - and set -e then aborts the whole
# install before the plugin step. Gate access HERE with a readable message
# and offer one re-login with a different account.
GH_LOGIN="$(gh api user --jq .login 2>/dev/null || echo '?')"
if ! gh repo view "$PLATFORM_REPO" >/dev/null 2>&1; then
  warn "Signed in as '$GH_LOGIN', but this account cannot access $PLATFORM_REPO."
  note "Wrong account? Or this account was never given access - ask an admin"
  note "to add you to the HubleDigital org / platform repo."
  RELOGIN="n"
  if $INTERACTIVE; then
    ask "  Sign in with a different GitHub account now? (y/N)" RELOGIN "n"
  fi
  case "$RELOGIN" in
    [Yy]*)
      gh_login
      GH_LOGIN="$(gh api user --jq .login 2>/dev/null || echo '?')"
      ;;
  esac
  gh repo view "$PLATFORM_REPO" >/dev/null 2>&1 \
    || fail "Account '$GH_LOGIN' has no access to $PLATFORM_REPO - ask an admin to grant access, then re-run this installer."
  ok "GitHub authenticated as $GH_LOGIN (platform access verified)"
fi

# ---------------------------------------------------------------- Platform repo
step "Installing the Huble platform"
# HUBLE_PLATFORM_UPDATE=0: use the platform already on this machine, touch
# nothing in its checkout. A client running INSIDE Obsidian passes this: the
# plugin has its own gated self-update (never auto-apply, refuse mid-run,
# hard stop on local changes) and must not have the platform swapped under
# it by a "new project" click.
PLATFORM_UPDATE_STATE="updated"
if [ "${HUBLE_PLATFORM_UPDATE:-1}" = "0" ]; then
  [ -d "$PLATFORM_DIR/.git" ] \
    || fail "The Huble platform is not installed on this Mac yet - run the installer once (Set up this Mac, or the curl line) before this action."
  PLATFORM_UPDATE_STATE="skipped"
  note "Platform update skipped (HUBLE_PLATFORM_UPDATE=0) - using the platform already on this machine."
elif [ -d "$PLATFORM_DIR/.git" ]; then
  note "Updating existing platform checkout..."
  # Re-point the remote UNCONDITIONALLY (same rule as the npm-prefix rewrite):
  # checkouts from before the org migration still aim at the old archived
  # repo and every pull dies with "Repository not found" - silently pinning
  # the whole machine to an ancient platform version.
  git -C "$PLATFORM_DIR" remote set-url origin "https://github.com/$PLATFORM_REPO.git"
  if ! git -C "$PLATFORM_DIR" pull --ff-only; then
    if [ -n "$(git -C "$PLATFORM_DIR" status --porcelain 2>/dev/null)" ]; then
      # Someone is hand-editing the platform (a local hotfix). A reset would
      # silently discard their work - never do that; leave it and be loud.
      warn "The platform checkout has local changes that block the update - commit, stash or discard them in $PLATFORM_DIR, then re-run."
      PLATFORM_UPDATE_FAILED=1
    else
      # Shallow/grafted clones can refuse to fast-forward across history gaps.
      # A CLEAN tool-managed checkout is safe to reset to the remote tip, and
      # that beats staying stale forever.
      note "Fast-forward failed - resetting the tool-managed checkout to the latest platform."
      git -C "$PLATFORM_DIR" fetch --depth 1 origin main \
        && git -C "$PLATFORM_DIR" reset --hard FETCH_HEAD \
        || PLATFORM_UPDATE_FAILED=1
    fi
  fi
  if [ -n "${PLATFORM_UPDATE_FAILED:-}" ]; then
    PLATFORM_UPDATE_STATE="failed"
    # A stale platform silently pins every vault this machine touches to an
    # old plugin/pipeline (field incident: 0.1.0 plugin installed by cx init
    # months after fixes shipped). Be LOUD here and again in the summary.
    warn "PLATFORM NOT UPDATED - everything below installs the OLD version already on this machine."
    warn "Usual cause: this GitHub account cannot read $PLATFORM_REPO (run: gh auth status) or no network."
  fi
  # Older installs sparse-checked plugins/ too; narrow them to the pipeline.
  # `docs` rides along: it is the platform manual the plugin's Get Started
  # "Open docs" row reads from <platform>/docs - a cone without it leaves every
  # machine on the "manual not on this machine yet" notice.
  if [ -f "$PLATFORM_DIR/.git/info/sparse-checkout" ]; then
    git -C "$PLATFORM_DIR" sparse-checkout set --cone huble-pipeline docs 2>/dev/null || true
  fi
else
  # Team machines need the pipeline (it carries the committed plugin dist
  # huble-pipeline/dist/atlas-cx that cx init installs from) plus docs (the
  # platform manual opened from the plugin). No plugin sources, no client
  # vaults, no planning docs.
  gh repo clone "$PLATFORM_REPO" "$PLATFORM_DIR" -- --depth 1 --sparse
  git -C "$PLATFORM_DIR" sparse-checkout set --cone huble-pipeline docs
fi
HUBLE="$PLATFORM_DIR/huble-pipeline/bin/huble"
[ -x "$HUBLE" ] || chmod +x "$HUBLE" 2>/dev/null || true
[ -f "$HUBLE" ] || fail "Platform clone incomplete: $HUBLE not found."
# Bare `huble` must work in any terminal - the README and the pipeline's own
# output tell users to run it unprefixed, so link it into the PATH dir the
# installer persists above.
mkdir -p "$HUBLE_HOME/bin"
ln -sf "$HUBLE" "$HUBLE_HOME/bin/huble"
ok "Platform at $PLATFORM_DIR"

# ---------------------------------------------------------------- Claude Code CLI
step "Checking Claude Code (agent CLI)"
if command -v claude >/dev/null 2>&1; then
  ok "Claude Code $(claude --version 2>/dev/null | head -1 || true)"
else
  note "Installing Claude Code..."
  claude_installed=true
  if ! npm install -g @anthropic-ai/claude-code </dev/null >/dev/null 2>&1; then
    if $IS_ADMIN && $INTERACTIVE; then
      sudo npm install -g @anthropic-ai/claude-code </dev/null >/dev/null || claude_installed=false
    else
      # npm's global prefix is not writable: use a user-level prefix instead.
      npm config set prefix "$HUBLE_HOME/npm-global"
      npm install -g @anthropic-ai/claude-code </dev/null >/dev/null || claude_installed=false
      ensure_path_persisted
    fi
  fi
  if $claude_installed; then
    ok "Claude Code installed"
    note "After this installer finishes, run:  claude login"
  else
    # Not vault-blocking - keep going and let the user add it afterwards.
    warn "Claude Code install failed - install later with: npm install -g @anthropic-ai/claude-code"
  fi
fi

# ---------------------------------------------------------------- dex (task tracker CLI)
step "Checking dex (task tracker CLI)"
if command -v dex >/dev/null 2>&1; then
  ok "dex $(dex --version 2>/dev/null | head -1 || true)"
else
  note "Installing dex..."
  # Same fallback chain as Claude Code above: plain npm -g, then sudo for
  # admins, then a user-level npm prefix for everyone else.
  dex_installed=true
  if ! npm install -g @zeeg/dex </dev/null >/dev/null 2>&1; then
    if $IS_ADMIN && $INTERACTIVE; then
      sudo npm install -g @zeeg/dex </dev/null >/dev/null || dex_installed=false
    else
      # npm's global prefix is not writable: use a user-level prefix instead.
      npm config set prefix "$HUBLE_HOME/npm-global"
      npm install -g @zeeg/dex </dev/null >/dev/null || dex_installed=false
      ensure_path_persisted
    fi
  fi
  if $dex_installed; then
    ok "dex installed"
  else
    # Not vault-blocking - keep going and let the user add it afterwards.
    warn "dex install failed - install later with: npm install -g @zeeg/dex"
  fi
fi

# ---------------------------------------------------------------- Installer state
# ~/.huble/installer.json remembers this machine's defaults (role, vaults
# folder, last vault). It replaces the old ~/.huble/machine.json, whose name
# collided with the per-vault <vault>/.huble/machine.json written by cx init.
# The vault's own file always wins for that vault; installer.json is only
# the default the installer offers. Needs Node (json helpers) - so it lives
# after the toolchain steps.
if [ -f "$HUBLE_HOME/machine.json" ] && [ ! -f "$INSTALLER_STATE" ]; then
  OLD_LAST="$(json_read "$HUBLE_HOME/machine.json" lastVault)"
  [ -n "$OLD_LAST" ] && json_write "$INSTALLER_STATE" lastVault "$OLD_LAST"
  rm -f "$HUBLE_HOME/machine.json"
  note "Migrated ~/.huble/machine.json to installer.json"
fi
STORED_ROLE="$(json_read "$INSTALLER_STATE" role)"
STORED_VAULTS_DIR="$(json_read "$INSTALLER_STATE" vaultsDir)"
if [ -z "${HUBLE_VAULTS_DIR:-}" ] && [ "$LAUNCH_DIR" = "$HOME" ] && [ -n "$STORED_VAULTS_DIR" ] && [ -d "$STORED_VAULTS_DIR" ]; then
  VAULTS_DIR="$STORED_VAULTS_DIR"
fi

# ---------------------------------------------------------------- Client vault
VAULT_MODE="${HUBLE_VAULT_MODE:-}"
case "$VAULT_MODE" in
  new|clone|skip|remove|"") ;;
  *) fail "HUBLE_VAULT_MODE must be new, clone, skip or remove (got '$VAULT_MODE')." ;;
esac
# The step label names what this run does to a vault (a GUI shows it as the
# progress row). Only the interactive menu path gets the generic label.
if [ -n "$VAULT_MODE" ]; then
  case "$VAULT_MODE" in
    new)    step "Creating ${HUBLE_CLIENT_NAME:-a new client vault}" ;;
    clone)  step "Cloning ${HUBLE_VAULT_REPO:-a client vault}" ;;
    remove) step "Removing $(basename "${HUBLE_VAULT_PATH:-a vault}") from this Mac" ;;
    skip)
      case "${HUBLE_VAULT_REINIT:-}" in
        no) ;;                                    # nothing vault-related happens - no step
        "") step "Setting up a client vault" ;;   # may offer a re-init below
        *)  step "Updating Atlas in $(basename "$HUBLE_VAULT_REINIT")" ;;
      esac ;;
  esac
else
  step "Setting up a client vault"
fi
if [ -z "$VAULT_MODE" ]; then
  if $INTERACTIVE; then
    printf '  How do you want to start?\n' > /dev/tty
    printf '    1) Clone an existing client vault from GitHub\n' > /dev/tty
    printf '    2) Create a new client vault\n' > /dev/tty
    printf '    3) Skip - I already have my vault\n' > /dev/tty
  fi
  ask "  Choose 1/2/3" choice "3"
  case "$choice" in
    1) VAULT_MODE="clone" ;;
    2) VAULT_MODE="new" ;;
    *) VAULT_MODE="skip" ;;
  esac
fi

# Role comes BEFORE vault setup so every install step (vault init included)
# is role-scoped from the start — no all-roles install followed by a re-filter.
ROLE="${HUBLE_ROLE:-}"
if [ -n "$ROLE" ] && ! valid_role "$ROLE"; then
  fail "HUBLE_ROLE must be one of cx, copy, seo, design, dev, all (got '$ROLE')."
fi
case "$VAULT_MODE" in new|clone) NEEDS_VAULT=true ;; *) NEEDS_VAULT=false ;; esac
if $NEEDS_VAULT && [ -z "$ROLE" ]; then
  if $INTERACTIVE; then
    note "Your role sets the Atlas Inspector tab and installs only that stage's"
    note "tooling + a sparse checkout of its slice of the vault."
  fi
  ask_role ROLE "$STORED_ROLE"
fi

if $NEEDS_VAULT; then
  mkdir -p "$VAULTS_DIR" || fail "Cannot create the vaults folder $VAULTS_DIR."
  note "Vaults folder: $VAULTS_DIR"
fi

# Obsidian reads obsidian.json only at startup and REWRITES it from memory on
# quit - editing it while Obsidian runs gets ignored and then overwritten.
# Quit it first and WAIT FOR THE QUIT TO FULLY FINISH (a slow quit flushes
# obsidian.json after the 10s mark and silently clobbers our edit - seen in
# the field). Returns 1 when Obsidian would not quit.
obsidian_running() { pgrep -xq Obsidian; }
quit_obsidian() {
  obsidian_running || return 0
  note "Quitting Obsidian..."
  osascript -e 'tell application "Obsidian" to quit' >/dev/null 2>&1 || true
  local i=0
  while [ "$i" -lt 30 ]; do
    obsidian_running || break
    sleep 1
    i=$((i+1))
  done
  if obsidian_running; then return 1; fi
  sleep 2   # let the final config flush land before we write
  return 0
}
unregister_vault() { # unregister_vault /abs/path - drop it from Obsidian's vault list
  node -e '
    const fs = require("fs"), path = require("path"), os = require("os");
    const cfgPath = path.join(os.homedir(), "Library/Application Support/obsidian/obsidian.json");
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch { process.exit(0); }
    const target = process.argv[1];
    let changed = false;
    for (const [id, v] of Object.entries(cfg.vaults || {})) {
      if (v && v.path === target) { delete cfg.vaults[id]; changed = true; }
    }
    if (changed) fs.writeFileSync(cfgPath, JSON.stringify(cfg));
  ' "$1"
}
# obsidian_open_state /abs/path -> "true|false N": is THIS vault open in
# Obsidian, and how many OTHER vaults are open (decides whether a relaunch
# after a forced quit would land the user somewhere sensible).
obsidian_open_state() {
  node -e '
    const fs = require("fs"), path = require("path"), os = require("os");
    const cfgPath = path.join(os.homedir(), "Library/Application Support/obsidian/obsidian.json");
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch {}
    let mine = false, others = 0;
    for (const v of Object.values(cfg.vaults || {})) {
      if (!v || !v.open) continue;
      if (v.path === process.argv[1]) mine = true; else others++;
    }
    process.stdout.write((mine ? "true" : "false") + " " + others);
  ' "$1" 2>/dev/null || printf 'false 0'
}
# Obsidian rewrites obsidian.json from memory on quit, so an entry removed
# while it runs comes back. Entries that could not be dropped safely are
# queued here and dropped at the next moment Obsidian is not running.
FORGET_QUEUE="$HUBLE_HOME/obsidian-forget.txt"
queue_forget() {
  mkdir -p "$HUBLE_HOME"
  grep -qxF -- "$1" "$FORGET_QUEUE" 2>/dev/null || printf '%s\n' "$1" >> "$FORGET_QUEUE"
}
apply_pending_forgets() {
  [ -f "$FORGET_QUEUE" ] || return 0
  obsidian_running && return 0
  local p
  while IFS= read -r p; do [ -n "$p" ] && unregister_vault "$p"; done < "$FORGET_QUEUE"
  rm -f "$FORGET_QUEUE"
  note "Dropped previously removed vault(s) from Obsidian's vault list."
}
move_to_trash() { # move_to_trash /abs/path - Finder Trash (recoverable), mv fallback
  if osascript -e 'on run argv' -e 'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)' -e 'end run' "$1" >/dev/null 2>&1; then
    return 0
  fi
  local dest="$HOME/.Trash/$(basename "$1")" n=1
  while [ -e "$dest" ]; do dest="$HOME/.Trash/$(basename "$1") $n"; n=$((n+1)); done
  mv "$1" "$dest"
}

# Client vaults are the org repos tagged with the vault topic - names carry
# no signal (other teams create client-* repos that are not vaults). gh only
# lists what THIS account can read, so the list is already role/team scoped.
list_vault_repos() { # -> lines of "owner/name<TAB>description", sorted by name
  gh repo list "$VAULT_ORG" --topic "$VAULT_TOPIC" --limit 500 \
    --json nameWithOwner,description --jq 'sort_by(.nameWithOwner)[] | [.nameWithOwner, (.description // "")] | @tsv' 2>/dev/null
}
choose_vault_repo() { # interactive: numbered list from GitHub, or a typed owner/name
  local repos n i line pick
  note "Looking up client vaults on GitHub ($VAULT_ORG, topic $VAULT_TOPIC)..."
  repos="$(list_vault_repos || true)"
  if [ -z "$repos" ]; then
    note "No tagged client vaults visible to this account (or the lookup failed)."
    ask "  Vault repo (owner/name)" REPO "" HUBLE_VAULT_REPO
    return
  fi
  n=0
  while IFS=$'\t' read -r line _; do
    n=$((n+1))
    printf '    %2d) %s\n' "$n" "$line" > /dev/tty
  done <<< "$repos"
  while :; do
    ask "  Choose a number, or type owner/name" pick ""
    case "$pick" in
      */*) REPO="$pick"; return ;;
      ''|*[!0-9]*) warn "Enter a number from the list or owner/name." ;;
      *)
        i=0
        while IFS=$'\t' read -r line _; do
          i=$((i+1))
          if [ "$i" -eq "$pick" ]; then REPO="$line"; return; fi
        done <<< "$repos"
        warn "No entry $pick." ;;
    esac
  done
}

VAULT_PATH=""
case "$VAULT_MODE" in
  clone)
    REPO="${HUBLE_VAULT_REPO:-}"
    if [ -z "$REPO" ]; then
      if $INTERACTIVE; then choose_vault_repo; else fail "Non-interactive run: set HUBLE_VAULT_REPO=owner/name for HUBLE_VAULT_MODE=clone."; fi
    fi
    case "$REPO" in */*) ;; *) REPO="$VAULT_ORG/$REPO" ;; esac
    VAULT_PATH="$VAULTS_DIR/$(basename "$REPO")"
    if [ -d "$VAULT_PATH/.git" ]; then
      git -C "$VAULT_PATH" pull --ff-only || true
    else
      # Pre-check access so a wrong/unauthorized account gets guidance instead
      # of a GraphQL error that kills the install before the plugin step.
      if ! gh repo view "$REPO" >/dev/null 2>&1; then
        fail "Cannot access $REPO as '$(gh api user --jq .login 2>/dev/null || echo '?')' - check the owner/name spelling and that THIS GitHub account was added to the repo (collaborator or org team), then re-run."
      fi
      gh repo clone "$REPO" "$VAULT_PATH" \
        || fail "Clone of $REPO failed - see the git error above; fix it and re-run this installer (the vault plugin installs right after the clone, so nothing else was set up yet)."
    fi
    ;;
  new)
    CLIENT="${HUBLE_CLIENT_NAME:-}"
    if [ -z "$CLIENT" ]; then ask "  Client name" CLIENT "" HUBLE_CLIENT_NAME; fi
    [ -n "$CLIENT" ] || fail "Client name required."
    case "$CLIENT" in */*|.*) fail "Client name '$CLIENT' cannot contain '/' or start with '.'." ;; esac
    VAULT_PATH="$VAULTS_DIR/$CLIENT"
    "$HUBLE" vault init --client "$CLIENT" --vault "$VAULT_PATH" --role "$ROLE"
    ;;
  remove)
    # "Remove from this Mac": Trash the folder (recoverable), forget it in
    # Obsidian and installer.json. The GitHub repository is NEVER touched -
    # other machines hold clones and the project can be opened again any
    # time. Unsynced work blocks the removal unless HUBLE_FORCE=1 (a client
    # asks the user a second time before setting that).
    REMOVE_PATH="${HUBLE_VAULT_PATH:-}"
    if [ -z "$REMOVE_PATH" ]; then ask "  Vault folder to remove" REMOVE_PATH "" HUBLE_VAULT_PATH; fi
    REMOVE_PATH="$(clean_path "$REMOVE_PATH")"
    [ -d "$REMOVE_PATH" ] || fail "No folder at $REMOVE_PATH."
    REMOVE_PATH="$(cd "$REMOVE_PATH" && pwd -P)"
    # Never a home folder, a drive root or anything that shallow (a vault is
    # at least /Users/<me>/<vault> or /Volumes/<drive>/<vault> deep).
    DEPTH="$(printf '%s' "$REMOVE_PATH" | tr -cd '/' | wc -c | tr -d ' ')"
    if [ "$REMOVE_PATH" = "$HOME" ] || [ "$DEPTH" -lt 3 ]; then fail "Refusing to remove $REMOVE_PATH."; fi
    if [ ! -e "$REMOVE_PATH/.huble" ] && [ ! -f "$REMOVE_PATH/project-config.json" ]; then
      fail "$REMOVE_PATH is not a Huble vault (no .huble/ or project-config.json) - not touching it."
    fi
    note "Removing $REMOVE_PATH from this Mac (the GitHub repository stays)."
    UNSYNCED=""
    if [ -d "$REMOVE_PATH/.git" ]; then
      if [ -n "$(git -C "$REMOVE_PATH" status --porcelain 2>/dev/null)" ]; then
        UNSYNCED="uncommitted changes"
      fi
      if git -C "$REMOVE_PATH" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        AHEAD="$(git -C "$REMOVE_PATH" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
        [ "$AHEAD" -gt 0 ] && UNSYNCED="${UNSYNCED:+$UNSYNCED, }$AHEAD unpushed commit(s)"
      elif [ -z "$(git -C "$REMOVE_PATH" remote 2>/dev/null)" ]; then
        UNSYNCED="${UNSYNCED:+$UNSYNCED, }never pushed to GitHub"
      fi
    else
      UNSYNCED="not a git repository (nothing on GitHub)"
    fi
    if [ -n "$UNSYNCED" ] && [ "${HUBLE_FORCE:-}" != "1" ]; then
      warn "This vault has work that is not on GitHub: $UNSYNCED."
      if $INTERACTIVE; then
        ask "  Move it to the Trash anyway? (y/N)" REMOVE_ANYWAY "n"
        case "$REMOVE_ANYWAY" in [Yy]*) ;; *) fail "Removal cancelled - sync the vault to GitHub first." ;; esac
      else
        FAIL_REASON="unsynced"
        fail "This vault has work that is not on GitHub ($UNSYNCED). Sync it in Obsidian first, or remove anyway."
      fi
    fi
    # Quitting Obsidian closes EVERY open vault (and any agent chat in them),
    # so it happens only when THIS vault is open - it cannot be trashed
    # underneath a live window. A closed vault is trashed in place and its
    # list entry is queued (Obsidian would resurrect an edit made while it
    # runs); it is dropped the next time Obsidian is not running.
    VAULT_OPEN=false; OTHER_OPEN=0
    if obsidian_running; then
      OPEN_STATE="$(obsidian_open_state "$REMOVE_PATH")"
      VAULT_OPEN="${OPEN_STATE%% *}"; OTHER_OPEN="${OPEN_STATE##* }"
    fi
    if ! obsidian_running; then
      unregister_vault "$REMOVE_PATH"
      apply_pending_forgets
      note "Forgotten in Obsidian's vault list."
    elif [ "$VAULT_OPEN" = true ]; then
      note "This vault is open in Obsidian - quitting Obsidian to close it..."
      quit_obsidian || fail "Obsidian did not quit - close it yourself, then remove the vault again."
      unregister_vault "$REMOVE_PATH"
      apply_pending_forgets
      note "Forgotten in Obsidian's vault list."
    else
      queue_forget "$REMOVE_PATH"
      note "Obsidian stays open (this vault is not open in it) - it forgets the vault the next time it is closed."
    fi
    move_to_trash "$REMOVE_PATH" || fail "Could not move $REMOVE_PATH to the Trash."
    LAST_VAULT="$(json_read "$INSTALLER_STATE" lastVault)"
    [ "$LAST_VAULT" = "$REMOVE_PATH" ] && json_write "$INSTALLER_STATE" lastVault ""
    if [ "$VAULT_OPEN" = true ] && [ -z "${HUBLE_NO_OPEN:-}" ]; then
      if [ "$OTHER_OPEN" -gt 0 ]; then
        note "Reopening Obsidian with the other vault(s) that were open..."
        open -a Obsidian 2>/dev/null || open "$HOME/Applications/Obsidian.app" 2>/dev/null || true
      else
        note "Obsidian left closed - this was the only vault open in it."
      fi
    fi
    $JSON_OUT && emit vault path "$REMOVE_PATH"
    ok "Moved to the Trash: $REMOVE_PATH"
    ;;
  skip)
    [ "${HUBLE_VAULT_REINIT:-}" = "no" ] || note "Skipping vault setup (no new vault created)."
    # Re-runs default to skip, which used to leave the vault's plugin/skills/
    # commands on the old version while the platform updated underneath.
    # Offer a re-init of the existing vault so both move in lockstep;
    # declining (explicit no / Enter / no tty) keeps plain skip behavior.
    REINIT_VAULT="${HUBLE_VAULT_REINIT:-}"
    if [ "$REINIT_VAULT" = "no" ]; then
      REINIT_VAULT=""
    elif [ -z "$REINIT_VAULT" ]; then
      LAST_VAULT="$(json_read "$INSTALLER_STATE" lastVault)"
      if [ -n "$LAST_VAULT" ] && [ ! -d "$LAST_VAULT" ]; then LAST_VAULT=""; fi
      if $INTERACTIVE; then
        if [ -n "$LAST_VAULT" ]; then
          ask "  Update the vault at $LAST_VAULT too (plugin/skills/commands)? (Y/n)" UPDATE_VAULT "y"
          case "$UPDATE_VAULT" in [Yy]*) REINIT_VAULT="$LAST_VAULT" ;; esac
        else
          ask "  Update an existing vault's plugin/skills/commands too? (y/N)" UPDATE_VAULT "n"
          case "$UPDATE_VAULT" in
            [Yy]*) ask "  Vault path" REINIT_VAULT; REINIT_VAULT="$(clean_path "$REINIT_VAULT")" ;;
          esac
        fi
      fi
    fi
    if [ -n "$REINIT_VAULT" ]; then
      [ -d "$REINIT_VAULT" ] || fail "No vault folder at $REINIT_VAULT."
      # The vault remembers its role; only ask (and persist) when it doesn't.
      # The vault's recorded role wins; HUBLE_ROLE only fills the gap for a
      # vault that never recorded one (a client opening a folder from disk).
      REINIT_ROLE="$(json_read "$REINIT_VAULT/.huble/machine.json" role)"
      [ -z "$REINIT_ROLE" ] && [ -n "$ROLE" ] && REINIT_ROLE="$ROLE"
      # No role recorded: ask (or HUBLE_ROLE) and hand it to cx init, which
      # records it in the vault - the installer never writes that file
      # itself (some vaults track it in git, so a stray write from one
      # machine reaches every colleague).
      if [ -z "$REINIT_ROLE" ]; then ask_role REINIT_ROLE; fi
      note "Updating the vault's plugin/skills/commands (role: $REINIT_ROLE)..."
      "$HUBLE" cx init --vault "$REINIT_VAULT" --role "$REINIT_ROLE"
      json_write "$INSTALLER_STATE" lastVault "$REINIT_VAULT"
      $JSON_OUT && emit vault path "$REINIT_VAULT"
      ok "Vault at $REINIT_VAULT updated in lockstep with the platform"
    fi
    ;;
esac

# ---------------------------------------------------------------- Plugin + role tooling
if [ -n "$VAULT_PATH" ]; then
  step "Installing the Atlas plugin (role: $ROLE)"
  "$HUBLE" cx init --vault "$VAULT_PATH" --role "$ROLE"
  # Remember this vault, the role and the vaults folder so the next run (or a
  # GUI client) can offer them as defaults without re-asking for everything.
  # The vault's own .huble/machine.json role is recorded by cx init above,
  # never by the installer (see the re-init path for why).
  json_write "$INSTALLER_STATE" lastVault "$VAULT_PATH"
  json_write "$INSTALLER_STATE" role "$ROLE"
  json_write "$INSTALLER_STATE" vaultsDir "$VAULTS_DIR"
  $JSON_OUT && emit vault path "$VAULT_PATH"
  ok "Atlas plugin installed and enabled, role set to $ROLE"
fi

# A re-initialised vault is opened in Obsidian at the end exactly like a new
# or cloned one (unless HUBLE_NO_OPEN) - that is how a client "opens a
# project from this Mac". Set only AFTER the plugin step above so cx init
# does not run twice.
[ -z "$VAULT_PATH" ] && VAULT_PATH="${REINIT_VAULT:-}"

# ---------------------------------------------------------------- Poppler (PDF page rendering)
# Agents view PDF pages as images through pdftoppm when reading a PDF (brand
# guides, sitemap diagrams - anything where the text extraction alone is not
# enough). The pipeline itself no longer needs poppler (PDF text conversion is
# bundled), so this is agent tooling only: EVERY failure path below is
# non-fatal - decline, curl failure, brew failure all warn and continue.
# This step runs LAST on purpose: it is the only step that may spawn the
# Homebrew installer (sudo + Command Line Tools phases), and a first run must
# reach the vault payoff before the one fragile step.
step "Checking PDF page rendering (poppler)"
poppler_unavailable() {
  warn "PDF page rendering unavailable (agents will fall back to text sources); install later with: brew install poppler"
}
if command -v pdftoppm >/dev/null 2>&1; then
  ok "poppler (pdftoppm)"
else
  if ! command -v brew >/dev/null 2>&1; then
    if $IS_ADMIN && $INTERACTIVE; then
      note "poppler installs via Homebrew, which is not on this Mac yet."
      note "Why: agents render PDF pages as images with it - without it they can"
      note "only read a PDF's extracted text (diagram-heavy PDFs become unreadable)."
      note "Homebrew's official installer will ask for your macOS password once."
      ask "  Install Homebrew now? (y/N)" INSTALL_BREW "n"
      case "$INSTALL_BREW" in
        [Yy]*)
          BREW_INSTALL_SCRIPT="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh </dev/null)" || BREW_INSTALL_SCRIPT=""
          if [ -z "$BREW_INSTALL_SCRIPT" ]; then
            warn "Could not download the Homebrew installer (network issue?)."
          else
            # The Homebrew installer's sudo/CLT phase can SIGINT our whole
            # process group, killing this script silently. Shield the parent
            # with a ':' INT handler (a real handler, NOT SIG_IGN, so the
            # child stays Ctrl-C-able) and capture the child's status
            # explicitly instead of letting set -e or the default INT
            # disposition decide our fate. The child talks to the terminal
            # directly - never to our script pipe.
            trap ':' INT
            set +e
            /bin/bash -c "$BREW_INSTALL_SCRIPT" </dev/tty >/dev/tty 2>&1
            BREW_INSTALL_STATUS=$?
            set -e
            trap - INT
            if [ "$BREW_INSTALL_STATUS" -eq 0 ]; then
              # The Homebrew installer persists shellenv for future shells;
              # make brew visible to THIS run too (Apple Silicon, then Intel).
              if [ -x /opt/homebrew/bin/brew ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
              elif [ -x /usr/local/bin/brew ]; then
                eval "$(/usr/local/bin/brew shellenv)"
              fi
            else
              warn "Homebrew install failed or was cancelled."
            fi
          fi
          ;;
        *) note "Skipping Homebrew." ;;
      esac
    else
      # Homebrew's installer needs an admin account AND a terminal for its
      # password prompt - never prompt for a password this user does not
      # have, and never block a GUI client on one (same rule as the app installs).
      note "poppler installs via Homebrew, which needs an admin account in a terminal."
    fi
  fi
  if command -v brew >/dev/null 2>&1; then
    # On shared Macs Homebrew is often installed (and owned) by another user
    # account - brew install then fails with a wall of "not writable" errors
    # and suggests a chown that would steal the other user's Homebrew.
    # Preflight the prefix instead of letting brew crash into it.
    BREW_PREFIX="$(brew --prefix 2>/dev/null)" || BREW_PREFIX=""
    [ -n "$BREW_PREFIX" ] || BREW_PREFIX="$(dirname "$(dirname "$(command -v brew)")")"
    if [ -w "$BREW_PREFIX/Cellar" ] || { [ ! -e "$BREW_PREFIX/Cellar" ] && [ -w "$BREW_PREFIX" ]; }; then
      note "Installing poppler (PDF page rendering for agents)..."
      if brew install poppler </dev/null >/dev/null; then
        ok "poppler (pdftoppm) installed"
      else
        poppler_unavailable
      fi
    else
      warn "Homebrew at $BREW_PREFIX is owned by another user account on this Mac."
      warn "Ask that account to run: brew install poppler"
      poppler_unavailable
    fi
  else
    poppler_unavailable
  fi
fi

# ---------------------------------------------------------------- Done
step "Done"
# Any run that finds Obsidian closed is the safe moment to drop the list
# entries of vaults removed while it was open elsewhere.
obsidian_running || apply_pending_forgets
if [ -n "$VAULT_PATH" ]; then
  note "Vault: $VAULT_PATH"
  if [ -z "${HUBLE_NO_OPEN:-}" ]; then
    # Register (see quit_obsidian for why Obsidian must be down first),
    # relaunch, then VERIFY the entry survived.
    if quit_obsidian; then
      apply_pending_forgets
    else
      note "Obsidian is still shutting down - skipping auto-registration."
      note "Open the vault manually: vault picker > 'Open folder as vault' > $VAULT_PATH"
    fi
    register_vault() {
      node -e '
        const fs = require("fs"), path = require("path"), os = require("os");
        const cfgDir = path.join(os.homedir(), "Library/Application Support/obsidian");
        const cfgPath = path.join(cfgDir, "obsidian.json");
        fs.mkdirSync(cfgDir, { recursive: true });
        let cfg = {};
        try { cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch {}
        cfg.vaults = cfg.vaults || {};
        const vaultPath = process.argv[1];
        if (!Object.values(cfg.vaults).some(v => v.path === vaultPath)) {
          const id = Array.from({length: 16}, () => "0123456789abcdef"[Math.floor(Math.random()*16)]).join("");
          for (const v of Object.values(cfg.vaults)) delete v.open;
          cfg.vaults[id] = { path: vaultPath, ts: Date.now(), open: true };
          fs.writeFileSync(cfgPath, JSON.stringify(cfg));
        }
        process.stdout.write(encodeURIComponent(vaultPath));
      ' "$VAULT_PATH"
    }
    vault_registered() {
      node -e '
        const fs = require("fs"), path = require("path"), os = require("os");
        const cfgPath = path.join(os.homedir(), "Library/Application Support/obsidian/obsidian.json");
        let cfg = {};
        try { cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch {}
        const ok = Object.values(cfg.vaults || {}).some(v => v.path === process.argv[1]);
        process.exit(ok ? 0 : 1);
      ' "$VAULT_PATH"
    }
    note "Registering the vault with Obsidian..."
    ENCODED_PATH="$(register_vault)"
    note "Opening the vault in Obsidian..."
    open "obsidian://open?path=$ENCODED_PATH" 2>/dev/null \
      || open -a Obsidian 2>/dev/null \
      || open "$HOME/Applications/Obsidian.app" 2>/dev/null || true
    # Verify the registration survived the relaunch; a leftover quit-flush can
    # still clobber it. One silent retry, then a loud manual instruction.
    sleep 5
    if ! vault_registered; then
      note "Registration was overwritten - retrying once..."
      ENCODED_PATH="$(register_vault)"
      open "obsidian://open?path=$ENCODED_PATH" 2>/dev/null || true
      sleep 5
    fi
    if vault_registered; then
      note "Vault registered with Obsidian."
    else
      note "Could not register the vault automatically."
      note "In Obsidian: vault picker (bottom-left) > 'Open folder as vault' > $VAULT_PATH"
    fi
    note "Obsidian will ask you to trust the vault, then enable the Atlas plugin under Community plugins if prompted."
    note "If the vault does not open: in Obsidian's vault picker choose 'Open folder as vault' and select $VAULT_PATH"
  fi
fi
if [ -n "${PLATFORM_UPDATE_FAILED:-}" ]; then
  err "PLATFORM NOT UPDATED - this machine is still on the OLD platform version."
  err "Fix GitHub access to $PLATFORM_REPO (gh auth status) or network, then re-run this installer."
fi
# Save this installer locally so GUI clients (the Huble app, the Atlas
# plugin) run the exact same script without a terminal or a curl. When we
# were run from a file (a client calling ~/.huble/install.sh, or a checkout)
# copy that file; when piped through curl there is no file, so download.
save_self() {
  local target="$HUBLE_HOME/install.sh"
  if [ -f "$0" ] && grep -q '^INSTALLER_VERSION=' "$0" 2>/dev/null; then
    if [ "$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")" != "$target" ]; then
      cp -f "$0" "$target" && chmod +x "$target"
    fi
    return 0
  fi
  refresh_self
}
if save_self; then
  json_write "$INSTALLER_STATE" installerVersion "$INSTALLER_VERSION"
  note "Installer saved to $HUBLE_HOME/install.sh (GUI clients run this copy)"
else
  warn "Could not save a local copy of the installer to $HUBLE_HOME/install.sh - GUI clients will bootstrap via curl instead."
fi
note "Platform: $PLATFORM_DIR  (re-run this installer any time to update everything)"
$INTERACTIVE && note "The huble command works in NEW terminals (this one: run  source ~/.zshrc  first)."
if ! command -v claude >/dev/null 2>&1 || ! [ -e "$HOME/.claude" ]; then
  note "Remember to authenticate the agent CLI once:  claude login"
fi
bold ""
if $JSON_OUT; then
  if [ "$PLATFORM_UPDATE_STATE" = "updated" ]; then PU=true; else PU=false; fi
  emit done vault "${VAULT_PATH:-${REINIT_VAULT:-}}" platformUpdated "$PU" platformUpdate "$PLATFORM_UPDATE_STATE"
fi
