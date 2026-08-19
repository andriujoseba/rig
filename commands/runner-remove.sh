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
  gh api -X POST orgs/<org>/actions/runners/remove-token
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
A rejected token no longer abandons the runners after it: every target gets
its turn, and what did not come down is named at the end.

EXIT STATUS. A removal rig could not finish exits non-zero and lists the
runners still standing. rig cannot deregister a runner whose directory it
cannot read or cannot run config.sh in — there is no config.sh to talk to
GitHub with — but it stops their SERVICE either way, which needs only the
unit name. Finish those from Settings > Actions > Runners.

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
TOKEN_ENDPOINTS=""
if [ "$LOCAL" -eq 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    target_dir="$(printf '%s' "$line" | cut -f2)"
    if [ -e "$target_dir/.runner" ]; then
      NEEDS_TOKEN=1
      endpoint="$(runner_token_endpoint "$(runner_repo_url "$target_dir")" remove-token)"
      if [ -n "$endpoint" ] && ! printf '%s\n' "$TOKEN_ENDPOINTS" | grep -qxF "$endpoint"; then
        TOKEN_ENDPOINTS="${TOKEN_ENDPOINTS}${endpoint}
"
      fi
    fi
  done <<EOF
$TARGETS
EOF
fi
if [ "$NEEDS_TOKEN" -eq 1 ]; then
  REMOVE_TOKEN="${RUNNER_REMOVE_TOKEN:-}"
  TOKEN_COMMANDS="$(printf '%s' "$TOKEN_ENDPOINTS" | sed '/^$/d; s|^|  gh api -X POST |')"
  # Prompt only on a tty: headless, a bare `read` dies under set -e with no
  # message at all — the drill hit exactly this (wrong env var, exit 1, zero
  # output). Refuse loudly, naming both the variable and the tokenless out.
  if [ -z "$REMOVE_TOKEN" ]; then
    [ -t 0 ] || die "RUNNER_REMOVE_TOKEN is unset and stdin is not a tty — set RUNNER_REMOVE_TOKEN to run unattended, or use --local. Mint it from the endpoint matching each runner being removed:
${TOKEN_COMMANDS}"
    printf 'runner removal token (short-lived; matching endpoint):\n%s\n' "$TOKEN_COMMANDS" >&2
    read -rsp "token: " REMOVE_TOKEN || { echo; die "no removal token read (EOF) — set RUNNER_REMOVE_TOKEN to run unattended, or use --local"; }
    echo
  fi
  [ -n "$REMOVE_TOKEN" ] || die "empty removal token"
fi

# --- take one instance's service down -----------------------------------------
# stop_service <name> <dir> <unit> — 0 when the service is down, 1 when it is
# not and the operator has been told.
#
# Factored out because EVERY path through remove_one has to reach it, including
# the two that cannot deregister. Deregistering needs the directory, because
# config.sh lives in it; stopping the service needs only the unit name, which
# the systemd scan already gave us. Those are different requirements, and
# collapsing them is what let a discovered runner keep taking jobs under a
# reported removal.
stop_service() { # stop_service <name> <dir> <unit>
  local name="$1" dir="$2" unit="$3"

  if [ -n "$dir" ] && [ -e "$dir/.service" ]; then
    log "  stopping and uninstalling the service"
    if (cd "$dir" && ./svc.sh stop) && (cd "$dir" && ./svc.sh uninstall); then
      return 0
    fi
    warn "runner ${name}: could not take the service in ${dir} down"
    return 1
  fi

  if [ -n "$unit" ]; then
    # A unit rig did not record in .service — a hand-rolled sibling, or an
    # instance whose directory rig cannot read. svc.sh would not know about it,
    # so take it down through systemd directly.
    log "  stopping and disabling ${unit}"
    if systemctl disable --now "$unit"; then
      return 0
    fi
    warn "runner ${name}: could not disable ${unit} — stop it by hand: systemctl disable --now ${unit}"
    return 1
  fi

  log "  no service installed; skipping"
  return 0
}

# --- remove one instance ------------------------------------------------------
# 0 when the runner is fully gone, 1 when the teardown could not finish. The
# caller carries a non-zero return into the exit status: a removal rig could
# not complete must not report success, which is the whole of #166.
remove_one() { # remove_one <name> <dir> <unit>
  local name="$1" dir="$2" unit="$3" owner rc=0

  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    # No directory means no config.sh, so rig genuinely cannot deregister this
    # one from GitHub. It CAN stop the service — it knows the unit, because the
    # scan is what found this runner in the first place — and it must: this
    # path used to print `systemctl disable --now <unit>` for the operator,
    # never run it, and return 0, so `remove --all` exited successfully with a
    # discovered runner still taking jobs. That is the exact shape of the bug
    # this command exists to stop being.
    warn "runner ${name} (${unit:-unit unknown}) has no readable directory — rig cannot deregister it"
    stop_service "$name" "" "$unit" || rc=1
    if [ -n "$unit" ] && [ "$rc" -eq 0 ]; then
      warn "runner ${name}: service stopped, but it is still registered — delete it from Settings > Actions > Runners"
    fi
    [ -n "$unit" ] || warn "runner ${name}: no unit either; find it and take it down by hand"
    # Incomplete either way: the box has stopped taking jobs on it at best, and
    # the registration rig was asked to remove is still there.
    return 1
  fi
  # The unit counts: a hand-rolled sibling whose registration is already gone
  # server-side still has a service taking jobs, and returning here would leave
  # it running while reporting the runner removed.
  if [ ! -e "$dir/.runner" ] && [ ! -e "$dir/.service" ] && [ -z "$unit" ]; then
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
    # Same shape as the unreadable directory above: rig will not deregister
    # this one, but the service is still rig's to stop, and leaving it up while
    # reporting the runner removed is the failure being fixed. Incomplete, so
    # non-zero.
    stop_service "$name" "$dir" "$unit" || true
    return 1
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
  stop_service "$name" "$dir" "$unit" || rc=1

  if [ -e "$dir/.runner" ]; then
    local dereg=0
    if [ "$LOCAL" -eq 1 ]; then
      log "  wiping the local registration only (--local)"
      if (cd "$dir" && runuser -u "$owner" -- env HOME="$owner_home" \
        ./config.sh remove --local); then
        dereg=1
        warn "a stale offline runner is still listed in the repo — delete it from Settings > Actions > Runners"
      fi
    else
      log "  deregistering from GitHub ($(runner_token_endpoint "$(runner_repo_url "$dir")" remove-token))"
      if (cd "$dir" && runuser -u "$owner" -- env HOME="$owner_home" \
        ./config.sh remove --token "$REMOVE_TOKEN"); then
        dereg=1
      fi
    fi
    # A failed deregistration is reported and survived, not died on. Under
    # --all this used to kill the script through `set -e` partway down the
    # list — one removal token serves one repository, so a box whose runners
    # span two repos took the first few down and left the rest untouched, with
    # the failure landing mid-teardown. The exit status carries it now, so
    # every remaining target still gets its turn.
    if [ "$dereg" -eq 0 ]; then
      warn "runner ${name}: deregistration failed — its registration is still in the repo"
      warn "  a removal token is per-repository and short-lived; --local wipes the box side without one"
      rc=1
    else
      rm -f "$dir/.rig-labels"
    fi
  fi

  # .rig-instance stays. It is the name, not the registration: the binary is
  # deliberately left behind for the next install, and that install has to find
  # THIS directory rather than build a sibling beside it.
  if [ "$rc" -eq 0 ]; then
    log "  runner ${name} removed; the binary stays at ${dir} for a future rig runner install"
  else
    warn "runner ${name}: removal did not finish — see the warnings above"
  fi
  return "$rc"
}

# The heredoc, not a pipe: the loop must run in THIS shell so INCOMPLETE
# survives it. Every target gets its turn even when one fails, and the failures
# are collected rather than thrown away.
INCOMPLETE=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  RNAME="$(printf '%s' "$line" | cut -f1)"
  remove_one \
    "$RNAME" \
    "$(printf '%s' "$line" | cut -f2)" \
    "$(printf '%s' "$line" | cut -f3)" \
  || INCOMPLETE="${INCOMPLETE}  ${RNAME}
"
done <<EOF
$TARGETS
EOF

# A teardown that could not finish is not a success. Exiting 0 here — with a
# service still up, or a registration still live in the repo — is precisely the
# command that looks like it did the whole job (#166).
if [ -n "$INCOMPLETE" ]; then
  printf 'rig-runner: ERROR: %s\n' \
"these runners did not come down completely:
${INCOMPLETE%$'\n'}
rig runner status shows what is still on this box." >&2
  exit 1
fi
