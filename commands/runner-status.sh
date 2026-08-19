#!/usr/bin/env bash
# rig runner status — what runners does this box run, and what are they on?
# Read-only: reports what is already on the box. No credential, no network call.
#
# With no --name this LISTS, and the listing is the point (#166): a box running
# four runners used to report one, which is a command that looks like it did
# the whole job. Discovery scans systemd's actions.runner.* units rather than a
# registry rig keeps, so the siblings someone registered by hand — the ordinary
# way to get concurrency out of one host — appear as `unmanaged` instead of not
# appearing at all.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/runner-config.sh
. "$HERE/lib/runner-config.sh"

log() { printf 'rig-runner: %s\n' "$*"; }
die() { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner status [--name <name>] [--user <name>]

  --name <name>   report one instance in detail (default: list them all)
  --user <name>   unprivileged service user (default: github-runner)

With no --name, lists every runner on this box: name, registration scope and
target, install directory, systemd unit and its state, and whether rig manages
it. Instances are found both under the runner user's ~/actions-runner and by
scanning systemd for actions.runner.* units, so a runner rig did not create is
listed as `unmanaged` rather than left out.

With --name, prints the detail view for that one instance: its repository or
organization scope, organization runner group when applicable, runner name,
recorded labels, install directory, and systemd unit and state.

Reads only the runners' own on-disk config — no GitHub token, no network
call. Exits 1 when this box runs no runner at all, or when --name matches
none of the ones it runs.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
RUNNER_USER="github-runner"
WANT_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
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

# --- guards ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"

# A missing runner user is no longer the end of the story: it means rig has
# installed nothing here, not that the box runs nothing. The systemd scan still
# has something to say, and saying it is the whole point of the listing.
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
    die "no runner on this box (nothing under ${BASE_DIR}, no actions.runner.* unit)"
  fi
  die "no runner on this box (no ${RUNNER_USER} user, no actions.runner.* unit)"
fi

# --- one instance in detail --------------------------------------------------
detail() { # detail <name> <dir> <unit> <managed|unmanaged>
  local name="$1" dir="$2" unit="$3" managed="$4" target_url scope group labels state service

  target_url="$(runner_repo_url "$dir")"
  scope="$(runner_scope_from_url "$target_url")"
  group="$(runner_record_value "$dir" group)"

  # GitHub owns the labels; the runner does not persist them locally. rig
  # records what it registered with, so a box installed before this existed —
  # or a runner rig never touched — reports the honest answer rather than a
  # guess.
  if [ -n "$(runner_record_value "$dir" labels)" ]; then
    labels="$(runner_record_value "$dir" labels)"
  else
    labels="(not recorded on this box — GitHub holds them; see the repo's Settings > Actions > Runners)"
  fi

  if [ -n "$unit" ]; then
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    service="${unit} (${state:-unknown})"
  else
    service="(not installed as a service)"
  fi

  log "name:    ${name}"
  log "scope:   ${scope:-unknown}"
  log "target:  ${target_url:-unknown}"
  if [ "$scope" = "org" ]; then
    log "group:   ${group:-(not recorded on this box — defaults to Default when repointed)}"
  fi
  log "labels:  ${labels}"
  log "dir:     ${dir:-unknown}"
  log "service: ${service}"
  log "managed: ${managed}"
  if [ "$managed" = "unmanaged" ]; then
    log "         rig did not create this runner — it was registered here by hand."
    log "         remove and repoint can still select it by --name."
  fi
}

if [ -n "$WANT_NAME" ]; then
  if ! LINE="$(runner_pick "$WANT_NAME" "$INSTANCES")"; then
    die "no runner named '${WANT_NAME}' on this box. It runs:
$(runner_candidates "$INSTANCES")"
  fi
  if [ "$(printf '%s\n' "$LINE" | grep -c .)" -ne 1 ]; then
    die "more than one runner on this box answers to '${WANT_NAME}':
$(runner_candidates "$LINE")"
  fi
  # cut, not `read -r a b c d`: TAB is an IFS *whitespace* character, so read
  # collapses a run of them and an empty field would shift every field after
  # it. A unit-less instance has exactly that shape.
  detail \
    "$(printf '%s' "$LINE" | cut -f1)" \
    "$(printf '%s' "$LINE" | cut -f2)" \
    "$(printf '%s' "$LINE" | cut -f3)" \
    "$(printf '%s' "$LINE" | cut -f4)"
  exit 0
fi

# --- every instance on the box ------------------------------------------------
if [ "$COUNT" -eq 1 ]; then
  log "1 runner on this box:"
else
  log "${COUNT} runners on this box:"
fi
printf '%s\n' "$INSTANCES" | while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  L_NAME="$(printf '%s' "$LINE" | cut -f1)"
  L_DIR="$(printf '%s' "$LINE" | cut -f2)"
  L_UNIT="$(printf '%s' "$LINE" | cut -f3)"
  L_MANAGED="$(printf '%s' "$LINE" | cut -f4)"
  TARGET_URL="$(runner_repo_url "$L_DIR")"
  SCOPE="$(runner_scope_from_url "$TARGET_URL")"
  GROUP="$(runner_record_value "$L_DIR" group)"
  if [ -n "$L_UNIT" ]; then
    STATE="$(systemctl is-active "$L_UNIT" 2>/dev/null || true)"
    SERVICE="${L_UNIT} (${STATE:-unknown})"
  else
    SERVICE="(not installed as a service)"
  fi
  log "  ${L_NAME}  [${L_MANAGED}]"
  log "    scope:   ${SCOPE:-unknown}"
  log "    target:  ${TARGET_URL:-unknown}"
  [ "$SCOPE" != "org" ] || log "    group:   ${GROUP:-(not recorded; Default on repoint)}"
  log "    dir:     ${L_DIR:-unknown}"
  log "    service: ${SERVICE}"
done
log "detail for one: rig runner status --name <name>"
