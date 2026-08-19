#!/usr/bin/env bash
# rig runner repoint — move an installed runner across GitHub targets/scopes.
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
usage: rig runner repoint (--repo <owner/repo> | --org <org>) [options]

  --repo <owner/repo>   move the runner to one repository
  --org <org>           move the runner to an organization
  --runnergroup <name>  organization runner group (default: preserve the
                        recorded group, else Default)
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

Deregisters the runner from its current repository or organization and
registers it against exactly one of --repo/--org. Crossing scopes is stated
before anything is touched. The binary, user, and service are reused.

WHICH RUNNER. With one runner on the box, --name is optional and that runner
is the one. With several, its absence is refused with the list: moving one of
four and reporting success is what this flag exists to stop.
`rig runner status` lists them.

A runner rig did not create is refused here, with the two commands that do
it explicitly: re-registration goes through `rig runner install`, which
builds the instance in rig's own layout, so a "move" would leave the
original directory behind.

Two short-lived tokens, each minted from its OWN repository:

  RUNNER_REMOVE_TOKEN   removal token, from the CURRENT target (not needed
                        with --local)
      gh api -X POST repos/<current>/actions/runners/remove-token
      gh api -X POST orgs/<current-org>/actions/runners/remove-token
  RUNNER_TOKEN          registration token, from the target flag
      gh api -X POST repos/<new>/actions/runners/registration-token
      gh api -X POST orgs/<new-org>/actions/runners/registration-token

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
new one. Nothing is re-downloaded. A name another instance on this box
already answers to is refused before a token is asked for and before
anything comes down — including one held by a directory an earlier remove
left behind, which `status` does not list.

Convergent: repointing to the repo it is already on changes nothing, exits 0,
and never asks for a token — unless --rename asks for a change, which is a
re-registration and needs both. --rename naming the name it already has is
not a change.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
REPO=""
ORG=""
RUNNER_GROUP=""
RUNNER_GROUP_GIVEN=0
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
    --org)
      [ $# -ge 2 ] || die "--org needs a value" 2
      ORG="$2"; shift 2 ;;
    --runnergroup)
      [ $# -ge 2 ] || die "--runnergroup needs a value" 2
      RUNNER_GROUP="$2"; RUNNER_GROUP_GIVEN=1; shift 2 ;;
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
[ -z "$REPO" ] || [ -z "$ORG" ] || die "--repo and --org are mutually exclusive" 2
[ -n "$REPO" ] || [ -n "$ORG" ] || die "exactly one of --repo <owner/repo> or --org <org> is required" 2
if [ -n "$REPO" ] && ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  die "--repo must be owner/repo" 2
fi
if [ -n "$ORG" ] && ! printf '%s' "$ORG" | grep -qE '^[A-Za-z0-9_.-]+$'; then
  die "--org must be an organization name" 2
fi
if [ -n "$REPO" ] && [ "$RUNNER_GROUP_GIVEN" -eq 1 ]; then
  die "--runnergroup is only valid with --org" 2
fi
[ "$RUNNER_GROUP_GIVEN" -eq 0 ] || [ -n "$RUNNER_GROUP" ] || die "--runnergroup must not be empty" 2
case "${RUNNER_GROUP}${LABELS}" in
  *$'\n'*|*$'\r'*) die "--runnergroup and --labels must each be one line" 2 ;;
esac
if [ -n "$ORG" ]; then
  TARGET_SCOPE="org"; TARGET="$ORG"
else
  TARGET_SCOPE="repo"; TARGET="$REPO"
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
#
# The unfiltered set is kept as well, and only the rename check reads it: which
# runner this box RUNS is one question, whether a NAME is free is another, and
# a dormant directory answers the second just as loudly as a live one — the
# re-registration at the far end of a move goes through `install`, which does
# not filter either. See the rename guard below.
ALL_INSTANCES="$(runner_scan_units | runner_merge_instances "$BASE_DIR")"
INSTANCES="$(printf '%s\n' "$ALL_INSTANCES" | runner_live)"
COUNT="$(runner_count "$INSTANCES")"

[ "$COUNT" -gt 0 ] \
  || die "no runner on this box (nothing under ${BASE_DIR}, no actions.runner.* unit) — use: rig runner install"

LINE="$(runner_select_instance "$WANT_NAME" "$INSTANCES" \
"  rig runner repoint --${TARGET_SCOPE} ${TARGET} --name <name>")" || exit 1

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
  rig runner install --${TARGET_SCOPE} ${TARGET} --name ${RUNNER_NAME}"
fi

# Ownership answered, reach is the other question (#174 round 4). The listing
# spans the whole box — every actions.runner.* unit, whichever service user's
# home the instance lives in — and rig's own instances under ANOTHER user are
# `managed`, correctly. This verb still cannot move one: the install at the far
# end runs with the --user given here and chowns the instance directory to it,
# so a move across users would re-own that user's tree while reporting a
# routine repoint. It is refused above the tokens and above the teardown, with
# the same rule as everything else here — a move that cannot complete fails
# while the runner is still registered and still working.
#
# The unmanaged refusal comes first on purpose: for a hand-rolled runner "rig
# did not create it" is the terminal answer and no --user makes repoint work,
# so pointing at one would send the operator down a dead end.
if ! runner_dir_in_base "$BASE_DIR" "$RUNNER_DIR"; then
  OWNER="$(runner_dir_owner "$RUNNER_DIR")"
  die "runner ${RUNNER_NAME} lives at ${RUNNER_DIR}, outside ${BASE_DIR}:
it belongs to another service user, and repointing it as ${RUNNER_USER} would
re-own its directory. Nothing has been touched.${OWNER:+
Re-run it against the user that owns it:
  rig runner repoint --${TARGET_SCOPE} ${TARGET} --name ${RUNNER_NAME} --user ${OWNER}}"
fi

# --- the name it will answer to afterwards -----------------------------------
# Resolved here, above everything that can change the box, because both of the
# questions below turn on it: is this rename a change at all, and is the name
# it asks for free.
FINAL_NAME="${NEW_NAME:-$RUNNER_NAME}"

# A rename is checked against the box BEFORE a token is asked for and BEFORE
# anything is torn down (#174 round 2).
#
# The order used to be: remove (stop, uninstall, deregister) → rewrite
# .rig-instance to the new name → install → and only THEN the resolver noticing
# that two directories answer to it and refusing. That left the runner
# deregistered, and left it unreachable: the marker rewrite survives the
# failure, so --name <old> no longer finds the directory and --name <new> is
# refused as ambiguous. The recovery command the failure printed hit the same
# wall, and the only way back was hand-editing the box-local file this layout
# exists so nobody has to touch. A move that cannot complete must fail while
# the runner is still registered and still working — the same rule the tokens
# above are collected under.
#
# Against ALL_INSTANCES, not the live ones: a directory an earlier `remove`
# left behind holds the name just as firmly (its .rig-instance is what the
# install at the far end resolves against) and `status` does not list it, so
# nothing on the box would warn first.
#
# Excluded by DIRECTORY, not by name: after this, the selected instance is the
# one thing that may already answer to the new name — a re-run of a rename that
# got as far as the marker, or a name this instance already carries — and
# matching on the name would make the guard refuse itself.
if [ "$FINAL_NAME" != "$RUNNER_NAME" ]; then
  CLASH="$(printf '%s\n' "$ALL_INSTANCES" \
    | awk -F'\t' -v n="$FINAL_NAME" -v d="$RUNNER_DIR" 'NF && $1 == n && $2 != d')"
  if [ -n "$CLASH" ]; then
    die "the name '${FINAL_NAME}' already belongs to a runner on this box:
$(runner_candidates "$CLASH")
Renaming ${RUNNER_NAME} to it would leave two instances answering to
'${FINAL_NAME}', and the re-registration would then be refused with
${RUNNER_NAME} already deregistered. Nothing has been touched.
Pick another --rename, or take that one down first:
  rig runner remove --name ${FINAL_NAME}"
  fi
fi

# --- what is it registered to now? ------------------------------------------
CURRENT_URL="$(runner_repo_url "$RUNNER_DIR")"
CURRENT_SCOPE="$(runner_scope_from_url "$CURRENT_URL")"
RECORDED_SCOPE="$(runner_record_value "$RUNNER_DIR" scope)"
TARGET_URL="https://github.com/${TARGET}"
RECORDED_GROUP="$(runner_record_value "$RUNNER_DIR" group)"
if [ -n "$RECORDED_SCOPE" ] && [ "$RECORDED_SCOPE" != "$CURRENT_SCOPE" ]; then
  warn "recorded scope is ${RECORDED_SCOPE}, but the runner config says ${CURRENT_SCOPE}; using the runner config"
fi
if [ "$TARGET_SCOPE" = "org" ]; then
  if [ "$RUNNER_GROUP_GIVEN" -eq 0 ]; then
    if [ "$CURRENT_SCOPE" = "org" ] && [ -n "$RECORDED_GROUP" ]; then
      RUNNER_GROUP="$RECORDED_GROUP"
    else
      RUNNER_GROUP="Default"
    fi
  fi
else
  RUNNER_GROUP=""
fi

# FINAL_NAME against RUNNER_NAME, not "was --rename passed": the flag asking
# for the name the instance already has is not a change, and the help text
# promises exactly that convergence. Testing the flag instead sent
# `--rename solo` on the instance already called solo through the full
# teardown — stop, uninstall, deregister — to re-register it as itself.
if [ "$CURRENT_URL" = "$TARGET_URL" ] && [ "$CURRENT_SCOPE" = "$TARGET_SCOPE" ] \
  && [ "$FINAL_NAME" = "$RUNNER_NAME" ] \
  && { [ "$TARGET_SCOPE" != "org" ] \
    || { [ -z "$RECORDED_GROUP" ] && [ "$RUNNER_GROUP_GIVEN" -eq 0 ]; } \
    || [ "$RECORDED_GROUP" = "$RUNNER_GROUP" ]; }
then
  log "runner ${RUNNER_NAME} is already registered to ${TARGET_SCOPE} ${TARGET}; nothing to do"
  exit 0
fi
if [ -z "$LABELS" ]; then
  if [ -n "$(runner_record_value "$RUNNER_DIR" labels)" ]; then
    LABELS="$(runner_record_value "$RUNNER_DIR" labels)"
  else
    LABELS="ci-runner"
    warn "this box has no rig label record (installed before rig kept one)"
    warn "re-registering with the default labels: ${LABELS}"
    warn "if your workflows' runs-on expects anything else, ctrl-c and pass --labels"
  fi
fi

if [ "$CURRENT_SCOPE" = "org" ]; then
  CURRENT_WORDS="organization ${CURRENT_URL#https://github.com/}${RECORDED_GROUP:+ (runner group ${RECORDED_GROUP})}"
else
  CURRENT_WORDS="repository ${CURRENT_URL#https://github.com/}"
fi
if [ "$TARGET_SCOPE" = "org" ]; then
  TARGET_WORDS="organization ${TARGET} (runner group ${RUNNER_GROUP})"
else
  TARGET_WORDS="repository ${TARGET}"
fi
log "moving runner ${RUNNER_NAME} (${RUNNER_DIR}) from ${CURRENT_WORDS} to ${TARGET_WORDS}"
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

INSTALL_ARGS=(--"$TARGET_SCOPE" "$TARGET" --name "$FINAL_NAME" --labels "$LABELS" --user "$RUNNER_USER")
[ "$TARGET_SCOPE" != "org" ] || INSTALL_ARGS+=(--runnergroup "$RUNNER_GROUP")
if ! "$HERE/runner-install.sh" "${INSTALL_ARGS[@]}"
then
  warn "runner ${FINAL_NAME} is now deregistered from ${CURRENT_URL} and NOT registered anywhere"
  RECOVERY_GROUP=""
  [ "$TARGET_SCOPE" != "org" ] || RECOVERY_GROUP=" --runnergroup ${RUNNER_GROUP}"
  die "re-registration failed — fix the cause, then run: rig runner install --${TARGET_SCOPE} ${TARGET}${RECOVERY_GROUP} --name ${FINAL_NAME} --labels ${LABELS} --user ${RUNNER_USER}"
fi

log "runner ${FINAL_NAME} repointed to ${TARGET_URL}"
log "verify it shows Idle under that repo's Settings > Actions > Runners, and gone from the old one"
