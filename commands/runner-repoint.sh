#!/usr/bin/env bash
# rig runner repoint — move an installed runner from one repository to another.
# Deregister, then re-register against the new repo, reusing the binary that is
# already on the box.
#
# Selects ONE instance (#166). The old command moved whichever runner lived in
# the legacy directory and reported success while the box's other three kept
# taking jobs from the old repo — which is the bug, not the missing feature.
# On a box running several, --name is required.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/runner-config.sh
. "$HERE/lib/runner-config.sh"

log()  { printf 'rig-runner: %s\n' "$*"; }
warn() { printf 'rig-runner: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner repoint --repo <owner/repo> [options]

  --repo <owner/repo>   the repository to move the runner TO (required)
  --name <name>         which runner to move; required when this box runs
                        more than one
  --rename <name>       give it a new name at the far end (default: keep the
                        name it has now)
  --labels <csv>        runner labels (default: the labels rig recorded at
                        install; else ci-runner)
  --user <name>         unprivileged service user (default: github-runner)
  --local               skip the server-side deregistration of the OLD repo
                        (no removal token needed) — leaves a stale offline
                        runner listed there, to delete by hand

Deregisters the runner from the repository it is on now and registers it
against --repo. The runner binary, its user, and its systemd service are
reused, so nothing is downloaded.

WHICH RUNNER. With one runner on the box, --name is optional and that runner
is the one. With several, its absence is refused with the list: moving one of
four and reporting success is what this flag exists to stop.
`rig runner status` lists them.

A runner rig did not create is refused here, with the two commands that do
it explicitly: re-registration goes through `rig runner install`, which
builds the instance in rig's own layout, so a "move" would leave the
original directory behind.

Two short-lived tokens, each minted from its OWN repository:

  RUNNER_REMOVE_TOKEN   removal token, from the CURRENT repo (not needed
                        with --local)
      gh api -X POST repos/<current>/actions/runners/remove-token
  RUNNER_TOKEN          registration token, from the repo in --repo
      gh api -X POST repos/<new>/actions/runners/registration-token

Either may be typed at the prompt instead. Both are collected BEFORE the
runner is touched — a token you turn out not to have should fail while the
runner is still registered, not halfway through the move. Neither is written
to disk by rig.

LABELS ARE NOT RECOVERABLE FROM THE BOX: GitHub holds them and the runner
does not persist them. rig records what it registered with, but a runner
installed before rig did that has nothing to read — repoint then falls back
to the ci-runner default and says so. Check your workflows' runs-on.

--rename keeps the instance where it is on disk and changes what it is
called: the directory keeps the old name, and the name rig answers to is the
new one. Nothing is re-downloaded.

Convergent: repointing to the repo it is already on changes nothing, exits 0,
and never asks for a token — unless --rename asks for a change, which is a
re-registration and needs both.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
REPO=""
WANT_NAME=""
NEW_NAME=""
LABELS=""
RUNNER_USER="github-runner"
LOCAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo needs a value" 2
      REPO="$2"; shift 2 ;;
    --name)
      [ $# -ge 2 ] || die "--name needs a value" 2
      WANT_NAME="$2"; shift 2 ;;
    --rename)
      [ $# -ge 2 ] || die "--rename needs a value" 2
      NEW_NAME="$2"; shift 2 ;;
    --labels)
      [ $# -ge 2 ] || die "--labels needs a value" 2
      LABELS="$2"; shift 2 ;;
    --user)
      [ $# -ge 2 ] || die "--user needs a value" 2
      RUNNER_USER="$2"; shift 2 ;;
    --local) LOCAL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- validation ------------------------------------------------------------
[ -n "$REPO" ] || die "--repo <owner/repo> is required" 2
if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  die "--repo must be owner/repo" 2
fi
[ "$RUNNER_USER" != "root" ] || die "runner user must not be root" 2
if [ -n "$NEW_NAME" ] && ! runner_valid_name "$NEW_NAME"; then
  die "--rename must be letters, digits, dot, underscore or dash, and start with a letter or digit: '${NEW_NAME}'" 2
fi

# --- guards ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"

id -u "$RUNNER_USER" >/dev/null 2>&1 \
  || die "no runner installed (no ${RUNNER_USER} user) — use: rig runner install"
USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
BASE_DIR="$(runner_base_dir "$USER_HOME")"

# --- which runner? -----------------------------------------------------------
# runner_live, because a deregistered instance keeps its binary: the directory
# survives `remove` and the runner does not. Only `install` looks at those.
INSTANCES="$(runner_scan_units | runner_merge_instances "$BASE_DIR" | runner_live)"
COUNT="$(runner_count "$INSTANCES")"

[ "$COUNT" -gt 0 ] \
  || die "no runner on this box (nothing under ${BASE_DIR}, no actions.runner.* unit) — use: rig runner install"

LINE="$(runner_select_instance "$WANT_NAME" "$INSTANCES" \
"  rig runner repoint --repo ${REPO} --name <name>")" || exit 1

RUNNER_NAME="$(printf '%s' "$LINE" | cut -f1)"
RUNNER_DIR="$(printf '%s' "$LINE" | cut -f2)"

[ -n "$RUNNER_DIR" ] \
  || die "runner ${RUNNER_NAME} has no readable directory on this box — rig cannot move it"
[ -e "$RUNNER_DIR/.runner" ] \
  || die "no runner registered in ${RUNNER_DIR} — use: rig runner install"

# A move is a deregister plus an install, and install creates instances in
# rig's own layout. Run on a runner rig did not create, it would leave that
# directory behind and download a fresh runner somewhere else — a move that
# reports success and moves nothing. status and remove can still reach it; this
# one verb cannot, and says so rather than half-doing it.
if [ "$(printf '%s' "$LINE" | cut -f4)" = "unmanaged" ]; then
  die "runner ${RUNNER_NAME} (${RUNNER_DIR}) was not created by rig, and repoint
would not move it: re-registering goes through rig runner install, which builds
the instance in rig's layout and would leave ${RUNNER_DIR} behind.
Do it as two explicit steps, and rig will own it afterwards:
  rig runner remove --name ${RUNNER_NAME}
  rig runner install --repo ${REPO} --name ${RUNNER_NAME}"
fi

# --- what is it registered to now? ------------------------------------------
CURRENT_URL="$(runner_repo_url "$RUNNER_DIR")"
TARGET_URL="https://github.com/${REPO}"

if [ "$CURRENT_URL" = "$TARGET_URL" ] && [ -z "$NEW_NAME" ]; then
  log "runner ${RUNNER_NAME} is already registered to ${REPO}; nothing to do"
  exit 0
fi
if [ -z "$LABELS" ]; then
  if [ -r "$RUNNER_DIR/.rig-labels" ]; then
    LABELS="$(cat "$RUNNER_DIR/.rig-labels")"
  else
    LABELS="ci-runner"
    warn "this box has no rig label record (installed before rig kept one)"
    warn "re-registering with the default labels: ${LABELS}"
    warn "if your workflows' runs-on expects anything else, ctrl-c and pass --labels"
  fi
fi

FINAL_NAME="${NEW_NAME:-$RUNNER_NAME}"
log "moving runner ${RUNNER_NAME} (${RUNNER_DIR}) from ${CURRENT_URL} to ${TARGET_URL}"
[ "$FINAL_NAME" = "$RUNNER_NAME" ] || log "renaming it to ${FINAL_NAME}"
log "labels: ${LABELS}"
if [ "$COUNT" -gt 1 ]; then
  log "this box runs ${COUNT} runners; the other $((COUNT - 1)) are not touched"
fi

# --- tokens, both up front --------------------------------------------------
# Collected before anything is torn down: a missing or expired token must fail
# while the runner is still registered and working.
if [ "$LOCAL" -eq 0 ]; then
  RUNNER_REMOVE_TOKEN="${RUNNER_REMOVE_TOKEN:-}"
  # Prompt only on a tty — headless, a bare `read` dies under set -e with no
  # message (issue #42; same cure as runner-install/remove).
  if [ -z "$RUNNER_REMOVE_TOKEN" ]; then
    [ -t 0 ] || die "RUNNER_REMOVE_TOKEN is unset and stdin is not a tty — set RUNNER_REMOVE_TOKEN to run unattended, or use --local"
    read -rsp "removal token for ${CURRENT_URL} (short-lived): " RUNNER_REMOVE_TOKEN || { echo; die "no removal token read (EOF) — set RUNNER_REMOVE_TOKEN to run unattended, or use --local"; }
    echo
  fi
  [ -n "$RUNNER_REMOVE_TOKEN" ] || die "empty removal token"
  export RUNNER_REMOVE_TOKEN
fi

RUNNER_TOKEN="${RUNNER_TOKEN:-}"
if [ -z "$RUNNER_TOKEN" ]; then
  [ -t 0 ] || die "RUNNER_TOKEN is unset and stdin is not a tty — set RUNNER_TOKEN to run unattended"
  read -rsp "registration token for ${TARGET_URL} (short-lived): " RUNNER_TOKEN || { echo; die "no registration token read (EOF) — set RUNNER_TOKEN to run unattended"; }
  echo
fi
[ -n "$RUNNER_TOKEN" ] || die "empty registration token"
export RUNNER_TOKEN

# --- move -------------------------------------------------------------------
# By name in both directions: on a box running several, an unselected remove
# would take the wrong one down and an unselected install would build a
# sibling. remove keeps .rig-instance precisely so the install below resolves
# the name back to THIS directory and re-uses the binary already in it.
REMOVE_ARGS=(--user "$RUNNER_USER" --name "$RUNNER_NAME")
[ "$LOCAL" -eq 1 ] && REMOVE_ARGS+=(--local)
"$HERE/runner-remove.sh" "${REMOVE_ARGS[@]}"

# A rename moves the identity, not the directory: install resolves --name
# through .rig-instance, so writing the new name here is what makes it land in
# the directory that already holds the binary instead of a fresh sibling.
if [ "$FINAL_NAME" != "$RUNNER_NAME" ]; then
  printf '%s\n' "$FINAL_NAME" > "$RUNNER_DIR/.rig-instance"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/.rig-instance" 2>/dev/null || true
fi

if ! "$HERE/runner-install.sh" \
  --repo "$REPO" --name "$FINAL_NAME" --labels "$LABELS" --user "$RUNNER_USER"
then
  warn "runner ${FINAL_NAME} is now deregistered from ${CURRENT_URL} and NOT registered anywhere"
  die "re-registration failed — fix the cause, then run: rig runner install --repo ${REPO} --name ${FINAL_NAME} --labels ${LABELS} --user ${RUNNER_USER}"
fi

log "runner ${FINAL_NAME} repointed to ${TARGET_URL}"
log "verify it shows Idle under that repo's Settings > Actions > Runners, and gone from the old one"
