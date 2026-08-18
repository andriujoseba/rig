#!/usr/bin/env bash
# rig runner remove — take the service down and deregister the runner.
# Convergent: a box with nothing installed exits 0.
#
# Selects ONE instance (#166). On a box running several, removing "the runner"
# is not a thing anyone can mean: the old command took whichever one lived in
# the legacy directory, exited 0, and left the rest running — a command that
# looked like it did the whole job. Ambiguity is now refused by name, and
# --all is the teardown that used to be implied.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/runner-config.sh
. "$HERE/lib/runner-config.sh"

log()  { printf 'rig-runner: %s\n' "$*"; }
warn() { printf 'rig-runner: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner remove [options]

  --name <name>   which runner to remove; required when this box runs more
                  than one
  --all           remove every runner on this box, rig's and anyone else's
  --local         wipe this box's registration without contacting GitHub
                  (no token needed)
  --user <name>   unprivileged service user (default: github-runner)

Stops and uninstalls the systemd service, then deregisters the runner from
GitHub. The runner binary and its user stay on the box, so a later
`rig runner install` re-registers without downloading anything.

Provide the short-lived REMOVAL token — not a registration token, they are
different endpoints — via the RUNNER_REMOVE_TOKEN env var or the interactive
prompt:
  gh api -X POST repos/<owner/repo>/actions/runners/remove-token
It is consumed at deregistration and never written to disk by rig.

--local is the escape hatch for when the registration is already gone
server-side, or you cannot mint a token: the box is cleaned, but a stale
offline runner is left listed in the repo — delete it by hand from
Settings > Actions > Runners.

WHICH RUNNER. With one runner on the box, none of this shows: --name is
optional and that runner is the one. With several, --name is required and
its absence is refused with the list — the alternative is removing one of
four and reporting success. --all removes them all, INCLUDING runners rig
did not create: they are the reason a teardown that only knew about rig's
would leave the box still taking jobs. `rig runner status` lists them.
With --all, one removal token serves every runner on the same repository;
runners on different repositories need their own, so remove those by name.

Convergent: safe to re-run; a box with no runner installed exits 0.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
LOCAL=0
ALL=0
WANT_NAME=""
RUNNER_USER="github-runner"
while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL=1; shift ;;
    --all) ALL=1; shift ;;
    --name)
      [ $# -ge 2 ] || die "--name needs a value" 2
      WANT_NAME="$2"; shift 2 ;;
    --user)
      [ $# -ge 2 ] || die "--user needs a value" 2
      RUNNER_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- validation ------------------------------------------------------------
[ "$RUNNER_USER" != "root" ] || die "runner user must not be root" 2
if [ "$ALL" -eq 1 ] && [ -n "$WANT_NAME" ]; then
  die "--all and --name are mutually exclusive" 2
fi

# --- guards ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"

# --- what does this box run? -------------------------------------------------
# The runner user missing means rig installed nothing, not that the box runs
# nothing: the systemd scan still speaks, and --all must reach what it finds.
BASE_DIR=""
if id -u "$RUNNER_USER" >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
  BASE_DIR="$(runner_base_dir "$USER_HOME")"
fi

# runner_live, because a deregistered instance keeps its binary: the directory
# survives `remove` and the runner does not. Only `install` looks at those.
INSTANCES="$(runner_scan_units | runner_merge_instances "$BASE_DIR" | runner_live)"
COUNT="$(runner_count "$INSTANCES")"

if [ "$COUNT" -eq 0 ]; then
  if [ -n "$BASE_DIR" ]; then
    log "no runner on this box (nothing under ${BASE_DIR}, no actions.runner.* unit); nothing to remove"
  else
    log "no ${RUNNER_USER} user on this box and no actions.runner.* unit; nothing to remove"
  fi
  exit 0
fi

# --- pick the instances to remove -------------------------------------------
if [ "$ALL" -eq 1 ]; then
  TARGETS="$INSTANCES"
else
  TARGETS="$(runner_select_instance "$WANT_NAME" "$INSTANCES" \
"  rig runner remove --name <name>    one of them
  rig runner remove --all            all of them")" || exit 1
fi

# --- removal token — only when a server-side deregistration is pending -------
# Collected once, before anything is torn down: with --all, a token that turns
# out to be missing must fail while every runner is still registered and
# working, not after the first two are gone.
REMOVE_TOKEN=""
NEEDS_TOKEN=0
if [ "$LOCAL" -eq 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -e "$(printf '%s' "$line" | cut -f2)/.runner" ] && NEEDS_TOKEN=1
  done <<EOF
$TARGETS
EOF
fi
if [ "$NEEDS_TOKEN" -eq 1 ]; then
  REMOVE_TOKEN="${RUNNER_REMOVE_TOKEN:-}"
  # Prompt only on a tty: headless, a bare `read` dies under set -e with no
  # message at all — the drill hit exactly this (wrong env var, exit 1, zero
  # output). Refuse loudly, naming both the variable and the tokenless out.
  if [ -z "$REMOVE_TOKEN" ]; then
    [ -t 0 ] || die "RUNNER_REMOVE_TOKEN is unset and stdin is not a tty — set RUNNER_REMOVE_TOKEN to run unattended, or use --local"
    read -rsp "runner removal token (short-lived): " REMOVE_TOKEN || { echo; die "no removal token read (EOF) — set RUNNER_REMOVE_TOKEN to run unattended, or use --local"; }
    echo
  fi
  [ -n "$REMOVE_TOKEN" ] || die "empty removal token"
fi

# --- remove one instance ------------------------------------------------------
remove_one() { # remove_one <name> <dir> <unit>
  local name="$1" dir="$2" unit="$3" owner

  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    warn "runner ${name} (${unit}) has no readable directory — rig cannot deregister it"
    warn "stop and disable it by hand: systemctl disable --now ${unit}"
    return 0
  fi
  if [ ! -e "$dir/.runner" ] && [ ! -e "$dir/.service" ]; then
    log "runner ${name}: nothing registered in ${dir}; nothing to remove"
    return 0
  fi

  # config.sh must run as the user that owns the install, which for a runner
  # rig did not create is not necessarily --user. Take it from the directory,
  # and skip rather than die on a directory whose owner cannot be used: with
  # --all, dying here would abandon the runners after this one.
  local owner_home
  owner="$(stat -c '%U' "$dir" 2>/dev/null || true)"
  [ -n "$owner" ] || owner="$RUNNER_USER"
  owner_home="$(getent passwd "$owner" | cut -d: -f6)"
  if [ "$owner" = "root" ] || [ -z "$owner_home" ]; then
    warn "runner ${name}: ${dir} is owned by '${owner}', which rig will not run config.sh as"
    warn "deregister it by hand from that directory, as its owner"
    return 0
  fi

  log "removing runner ${name} (${dir})"

  # Record the name BEFORE tearing anything down. The binary is deliberately
  # left behind for the next install, and that install resolves --name to a
  # directory: without this, a runner whose identity lived only in .runner —
  # every box installed before .rig-instance existed — would lose it here, and
  # `install --name <it>` would then unpack a sibling beside the binary it was
  # meant to re-use. Before, not after, because a failed deregistration must
  # not be the thing that loses it.
  if [ ! -r "$dir/.rig-instance" ]; then
    printf '%s\n' "$name" > "$dir/.rig-instance"
    chown "$owner:$owner" "$dir/.rig-instance" 2>/dev/null || true
  fi

  # The service must come down FIRST in both paths. config.sh's removal throws
  # "Uninstall service first" while the service is configured; and `--local`
  # skips that check entirely, which would otherwise strand a running service
  # pointed at config that no longer exists.
  if [ -e "$dir/.service" ]; then
    log "  stopping and uninstalling the service"
    (cd "$dir" && ./svc.sh stop)
    (cd "$dir" && ./svc.sh uninstall)
  elif [ -n "$unit" ]; then
    # A unit rig did not record in .service — a hand-rolled sibling. svc.sh
    # would not know about it, so take it down through systemd directly.
    log "  stopping and disabling ${unit}"
    systemctl disable --now "$unit" || warn "  could not disable ${unit}"
  else
    log "  no service installed; skipping"
  fi

  if [ -e "$dir/.runner" ]; then
    if [ "$LOCAL" -eq 1 ]; then
      log "  wiping the local registration only (--local)"
      (cd "$dir" && runuser -u "$owner" -- env HOME="$owner_home" \
        ./config.sh remove --local)
      warn "a stale offline runner is still listed in the repo — delete it from Settings > Actions > Runners"
    else
      log "  deregistering from GitHub"
      (cd "$dir" && runuser -u "$owner" -- env HOME="$owner_home" \
        ./config.sh remove --token "$REMOVE_TOKEN")
    fi
    rm -f "$dir/.rig-labels"
  fi

  # .rig-instance stays. It is the name, not the registration: the binary is
  # deliberately left behind for the next install, and that install has to find
  # THIS directory rather than build a sibling beside it.
  log "  runner ${name} removed; the binary stays at ${dir} for a future rig runner install"
}

while IFS= read -r line; do
  [ -n "$line" ] || continue
  remove_one \
    "$(printf '%s' "$line" | cut -f1)" \
    "$(printf '%s' "$line" | cut -f2)" \
    "$(printf '%s' "$line" | cut -f3)"
done <<EOF
$TARGETS
EOF
