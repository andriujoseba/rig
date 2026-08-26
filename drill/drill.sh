#!/usr/bin/env bash
# drill/drill.sh — rig's release drill: the instrument behind drills/README.md.
#
#   ⚠ DESTRUCTIVE, AND MEANT TO BE. Run it on a THROWAWAY Debian machine you
#     can format. It wipes any installed rig and reinstalls from the pinned
#     ref, hardens sshd, sets the hostname, joins the tailnet, installs box
#     and its Incus stack, and installs Docker for the db round-trip.
#     Never run it on a machine you care about.
#
#   TS_AUTHKEY=tskey-... bash <(curl -fsSL \
#     https://raw.githubusercontent.com/heavy-duty/rig/release/0.4.0/drill/drill.sh) \
#     --rig-repo heavy-duty/rig --rig-ref release/0.4.0 --box-ref 0.9.0 \
#     --users-from-github danmt --run-id drill-2026-07-24-a --yes
#   (--box-ref is a tag: since #103 the box that ships is the BOX_RELEASE tag.)
# rig's drill asserts CONVERGENCE — a machine reaches its role, idempotently.
# The legs (drills/README.md, issue #105):
#
#   1. convergence + idempotence — `rig bootstrap <role> --users <path>`
#      reaches the declared role; a re-run produces an EMPTY state diff,
#      mechanically, never by eye. Rides along: the --host yes assertions
#      (the pinned box installed, its host stack stands — and it STOPS there;
#      the isolation boundary is box's drill's assertion, not this one's).
#   2. db — the real dump/restore round-trip, test/db-integration.sh.
#
# Execution order is 1, 2. The drill installs Debian's Docker package directly
# before leg 2 so the db round-trip is real even on a pristine machine. Docker
# provisioning is a prerequisite, not a rig surface or a separate evidence leg.
#
# Exit 0 = no check failed. A FAILED drill still emits a complete record —
# the gate wants evidence, not success — and skipped legs are counted and
# named, never folded into the passes (heavy-duty/box#153's defect class).
#
# The file is one long 'probe && ok "…" || no "…"'. ok/no always return 0, so
# the C-may-run-when-A-is-true trap SC2015 warns about cannot fire here.
# shellcheck disable=SC2015
#
# NOT -e: a failing check is data, not a crash — a drill that aborts on its
# first failure reports one problem per afternoon. NOT pipefail: checks of the
# 'refusal 2>&1 | grep -q text' shape have a left side that exits non-zero BY
# DESIGN, and 'grep -q' SIGPIPEs the left side on early match — box's first
# live run turned both into false FAILs. The pipeline verdict must be grep's
# alone. (box drill/drill.sh's header, the discipline #105 prescribes.)
set -u

REPO="${RIG_REPO:-heavy-duty/rig}"
REF="${RIG_REF:-}"
BOXREPO="${BOX_REPO:-heavy-duty/box}"
BOXREF="${BOX_REF:-}"
# The template registry the converge will read (#110). No explicitness
# demand here, unlike the two refs above: the DEFAULT is already a pin — the
# candidate tree's RIG_TEMPLATES_PIN, read after install from what actually
# landed — so an unset override means "the ref the release will really use",
# not "whatever main was that afternoon".
TPLREPO="${RIG_TEMPLATES_REPO:-heavy-duty/rig-templates}"
TPLREF="${RIG_TEMPLATES_REF:-}"
TPL_SHA=""
TPL_SOURCE="fetched"
ROLE=staging-server
USERS_FILE="${DRILL_USERS_FILE:-}"
USERS_FROM_GITHUB=""
GENERATED_USERS_FILE=""
RUN_ID="${DRILL_RUN_ID:-drill-$(date -u +%F)}"
RECORD="${DRILL_RECORD:-}"
YES=0

usage() {
  cat <<'EOF'
drill/drill.sh — rig's release drill: the instrument behind drills/README.md.

  ⚠ DESTRUCTIVE, AND MEANT TO BE. Run it on a THROWAWAY Debian machine you
    can format. It wipes any installed rig and reinstalls from the pinned
    ref, hardens sshd, sets the hostname, joins the tailnet, installs box
    and its Incus stack, and installs Docker for the db round-trip.
    Never run it on a machine you care about.

  TS_AUTHKEY=tskey-... bash <(curl -fsSL \
    https://raw.githubusercontent.com/heavy-duty/rig/release/0.4.0/drill/drill.sh) \
    --rig-repo heavy-duty/rig --rig-ref release/0.4.0 --box-ref 0.9.0 \
    --users-from-github danmt --run-id drill-2026-07-24-a --yes
  (--box-ref is a tag: since #103 the box that ships is the BOX_RELEASE tag.)

Options:
  --rig-repo <owner/repo>       rig repository (default: heavy-duty/rig)
  --rig-ref <ref>               required candidate branch or tag
  --box-repo <owner/repo>       box repository (default: heavy-duty/box)
  --box-ref <tag>               required box release tag
  --role <machine-role>         role to converge (default: staging-server)
  --users <path>                existing rig users ledger
  --users-from-github <handle>  render an admin,box ledger from public keys
  --run-id <id>                 shared drill run ID
  --record <path>               record destination
  --yes, -y                     skip the destructive confirmation
  --help, -h                    show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --rig-repo) REPO="$2"; shift 2 ;;
    --rig-ref) REF="$2"; shift 2 ;;
    --box-repo) BOXREPO="$2"; shift 2 ;;
    --box-ref) BOXREF="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --users) USERS_FILE="$2"; shift 2 ;;
    --users-from-github) USERS_FROM_GITHUB="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --record) RECORD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "drill: unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# --- the reporting verbs (box drill/drill.sh:52-58, the parts worth copying) --
# ok/no/skip/note always return 0: the body stays one long sequence of
# 'probe && ok || no' without fighting the shell. SKIP is its own verb and its
# own counter — a leg that did not run must be visually and arithmetically
# distinct from one that passed (box#153's defect class: a silent skip reads
# as a pass in the record, months later).
pass=0; fail=0; skipped=0; findings=()
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); findings+=("FAIL: $*"); }
skip() { printf '  \033[35mSKIP\033[0m  %s\n' "$*"; skipped=$((skipped + 1)); findings+=("SKIP: $*"); }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$*"; findings+=("NOTE: $*"); }
inf()  { printf '        %s\n' "$*"; }
phase(){ printf '\n\033[1m══ %s\033[0m\n' "$*"; }

# The record's leg table, appended as legs run. One row per leg, result text
# written at the moment the leg's verdict is known — never reconstructed from
# memory at the end (an invented number is worse than no number).
LEG_NAMES=(); LEG_RESULTS=()
leg() { LEG_NAMES+=("$1"); LEG_RESULTS+=("$2"); }

# run_logged <log> <cmd...> — run a long command with its narration in a file
# and a dot every 5s on the terminal: a silent multi-minute apt/install run is
# indistinguishable from a wedge, and that ambiguity has cost box whole
# evenings. Returns the command's exit code.
run_logged() {
  local log="$1"; shift
  inf "watch it live in another terminal:  tail -f $log"
  "$@" >"$log" 2>&1 </dev/null &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 5; done
  printf '\n'
  wait "$pid"
}

# tree_of <cli-path> — the versioned install tree a CLI's symlink chain lands
# in. Both rig and box install as <root>/versions/<v>/bin/<cli> behind a
# 'current' link, so the tree is two dirnames above the resolved binary —
# derived from the chain itself, never from a hardcoded install root (root vs
# user installs put the root in different places).
tree_of() {
  local real
  real="$(readlink -f "$1" 2>/dev/null)"
  # -e as well as -n: GNU readlink -f resolves a path whose LAST component
  # does not exist (exit 0), so a dangling link would hand back a tree that
  # is not there.
  { [ -n "$real" ] && [ -e "$real" ]; } || return 1
  dirname "$(dirname "$real")"
}

# assert_installed_from <what> <tree> <want> — ASSERT WHAT LANDED, never trust
# that the install obeyed. An installer invoked with stale env vars silently
# falls back to its defaults — sane ones since rig#103 landed (box: the
# BOX_RELEASE pin, rig: the latest release), which is what makes the fallback
# invisible — and a drill that thinks it exercised release/X but actually got
# whatever the defaults resolve to has proven nothing about the combination
# that ships — worse than one that fails, because the record it leaves LOOKS
# like evidence. Refusal names both refs, per #105's acceptance criteria.
assert_installed_from() {
  local what="$1" tree="$2" want="$3" got
  got="$(cat "$tree/INSTALLED_FROM" 2>/dev/null || echo '<unreadable>')"
  if [ "$got" != "$want" ]; then
    printf 'drill: FATAL — asked to install %s from %s, but the installed tree says %s.\n' "$what" "$want" "$got" >&2
    printf '  (tree: %s)\n' "$tree" >&2
    printf '  A drill that silently drills the wrong code is worse than one that fails:\n' >&2
    printf '  every result below would describe a tree that is not the candidate. Check\n' >&2
    printf '  the env this drill inherited (a stale RIG_REF/BOX_REF export), fix the\n' >&2
    printf '  pin, and re-run.\n' >&2
    return 1
  fi
  return 0
}

# classify_leg <rc> <outfile> — pass | skip | fail. The skip contract is
# test/db-integration.sh's, copied carefully: it skips CLEANLY (exit 0) with a
# 'skip: <reason>' line when it cannot run, so exit code alone reads a
# not-run leg as a pass. The reason line is the verdict's tiebreaker; a
# non-zero exit is a fail whatever the output says (a die after a skip line
# would be a broken harness, not a skip).
classify_leg() {
  local rc="$1" out="$2"
  if [ "$rc" -eq 0 ] && grep -q '^skip:' "$out" 2>/dev/null; then
    printf 'skip'
  elif [ "$rc" -eq 0 ]; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

# capture_state <outfile> — the convergent surface bootstrap owns, as one
# diffable text file. Leg 1's idempotence claim is decided by capturing this
# BEFORE and AFTER the re-run and diffing — mechanically, because idempotence
# is the single easiest property to convince yourself of by eye (#105).
#
# What is captured is what bootstrap CONVERGES, nothing that legitimately
# moves between two back-to-back runs: no package lists (unattended-upgrades
# may act between captures), no clocks. The manifest is included WHOLE on
# purpose — lib/manifest.sh's contract is that a same-version re-run renders
# byte-identical content (converged_at tracks the version, not the run), so
# the diff ENFORCES that contract instead of exempting it.
#
# Every path is overridable so test/drill.sh proves the capture-and-diff
# machinery against fixtures, without root (repo precedent: RIG_ROLE_MARKER,
# RIG_MANIFEST). Absent files and commands degrade to a deterministic
# '(absent)' — a capture must never fail, only describe.
capture_state() {
  local out="$1" marker manifest ledger autoup hosts u state home keys
  marker="${RIG_ROLE_MARKER:-/etc/rig/role}"
  manifest="${RIG_MANIFEST:-/etc/rig/manifest}"
  ledger="${DRILL_LEDGER:-/etc/rig/users}"
  autoup="${DRILL_AUTOUPGRADES:-/etc/apt/apt.conf.d/20auto-upgrades}"
  hosts="${DRILL_ETC_HOSTS:-/etc/hosts}"
  {
    printf 'hostname: %s\n' "$(hostname 2>/dev/null || echo '(absent)')"
    printf 'hosts.127.0.1.1: %s\n' "$(grep -E '^127\.0\.1\.1[[:space:]]' "$hosts" 2>/dev/null || echo '(absent)')"
    printf 'role-marker: %s\n' "$(cat "$marker" 2>/dev/null || echo '(absent)')"
    printf 'manifest:\n'
    sed 's/^/  /' "$manifest" 2>/dev/null || printf '  (absent)\n'
    printf 'auto-upgrades:\n'
    sed 's/^/  /' "$autoup" 2>/dev/null || printf '  (absent)\n'
    printf 'sshd-effective:\n'
    if command -v sshd >/dev/null 2>&1; then
      sshd -T 2>/dev/null | sort | sed 's/^/  /' || printf '  (sshd -T failed)\n'
    else
      printf '  (sshd absent)\n'
    fi
    # Self's Tags is the FIRST occurrence in the status JSON (Self serializes
    # before Peer). Tags only, nothing livelier: peers joining, IPs renewing
    # or a backend-state flap between two captures is not a convergence diff
    # on this box, and a capture that can move on its own poisons the
    # idempotence verdict with noise.
    printf 'tailscale.self.tags: %s\n' "$(tailscale status --json 2>/dev/null | tr -d '\n ' | grep -o '"Tags":\[[^]]*\]' | head -n1 || true)"
    printf 'users-ledger:\n'
    sed 's/^/  /' "$ledger" 2>/dev/null || printf '  (absent)\n'
    # Per-operator effective state: the account, its groups, its lock state,
    # its keys. sha256 of authorized_keys, not the keys themselves — the
    # capture may end up quoted in a record and keys are long, not secret.
    while read -r u state; do
      [ -n "${u:-}" ] || continue
      if ! id -u "$u" >/dev/null 2>&1; then
        printf 'user.%s: (no account)\n' "$u"
        continue
      fi
      printf 'user.%s: state=%s groups=%s lock=%s\n' "$u" "${state:-active}" \
        "$(id -Gn "$u" 2>/dev/null | tr ' ' ',')" \
        "$(passwd -S "$u" 2>/dev/null | awk '{print $2}' || echo '?')"
      home="$(getent passwd "$u" | cut -d: -f6)"
      keys="$home/.ssh/authorized_keys"
      printf 'user.%s.authorized_keys: %s\n' "$u" \
        "$(sha256sum "$keys" 2>/dev/null | cut -d' ' -f1 || echo '(none)')"
    done < <(cat "$ledger" 2>/dev/null)
    printf 'sudoers.d:\n'
    find "${DRILL_SUDOERS_DIR:-/etc/sudoers.d}" -maxdepth 1 -type f 2>/dev/null | sort \
      | while read -r u; do printf '  %s %s\n' "$(sha256sum "$u" | cut -d' ' -f1)" "$u"; done
    printf 'box: %s\n' "$(command -v box 2>/dev/null || echo '(absent)')"
  } > "$out"
}

# ref_sha <owner/repo> <ref> — the commit the record cites. Tags outrank
# branches (the installer's own precedence, install.sh:117-120). Resolved once
# up front and reused, so the record and the install describe the same instant
# even if the branch moves mid-drill. Empty on failure; the record then says
# 'unresolved' rather than inventing one.
ref_sha() {
  local sha
  sha="$(git ls-remote "https://github.com/$1" "refs/tags/$2" 2>/dev/null | head -n1 | cut -f1)"
  [ -n "$sha" ] || sha="$(git ls-remote "https://github.com/$1" "refs/heads/$2" 2>/dev/null | head -n1 | cut -f1)"
  printf '%s' "${sha:0:7}"
}

# default_record_path <version> — independent of the instrument's location:
# a curl-piped script has no checkout whose drills/ directory could own it.
default_record_path() {
  printf '/root/drills/%s.md' "$1"
}

# render_github_users <handle> — turn github.com/<handle>.keys on stdin into
# rig's ledger format. Every key grants the same operator roles by design.
render_github_users() {
  local user="$1"
  awk -v user="$user" 'NF && $1 !~ /^#/ { print user, "admin,box", $0 }'
}

# publish_record <path> — the final stdout payload: where the record lives,
# followed by the complete paste-ready record and nothing after it.
publish_record() {
  printf '\n        record written: %s\n\n' "$1"
  cat "$1"
}

# emit_record <path> — drills/<version>.md, in the shape drills/README.md
# defines: what ran, on what host, the pinned refs and SHAs, the numbers, and
# what failed. Emitted on EVERY completed run — a failed drill is still a
# valid record; the gate wants evidence, not success. Skipped legs are listed
# by name: a record with no failures listed reads as "nothing broke", so a leg
# that was not run says so instead of being omitted.
emit_record() {
  local out="$1" i os cpus ram virt line
  os="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
  cpus="$(nproc 2>/dev/null || echo '?')"
  ram="$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?')"
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  {
    printf '# Release drill — %s — %s\n\n' "$DRILL_VERSION" "$(date -u +%F)"
    printf 'Run ID: %s. Host: %s, %s vCPU / %s GB RAM (%s).\n' "$RUN_ID" "${os:-unknown}" "$cpus" "$ram" "$virt"
    printf 'Candidate refs: rig@%s (RIG_REF=%s), box@%s (BOX_REF=%s).\n' \
      "${RIG_SHA:-unresolved}" "$REF" "${BOX_SHA:-unresolved}" "$BOXREF"
    printf 'Template registry: %s@%s (ref %s, %s) — the rig-templates source the converge read (#110/#153).\n' \
      "${TPLREPO:-heavy-duty/rig-templates}" "${TPL_SHA:-unresolved}" \
      "${TPLREF:-unresolved}" "${TPL_SOURCE:-fetched}"
    printf 'Instrument: drill/drill.sh, legs in execution order.\n\n'
    printf '| Leg | Result |\n'
    printf '| --- | --- |\n'
    for i in "${!LEG_NAMES[@]}"; do
      printf '| %s | %s |\n' "${LEG_NAMES[$i]}" "${LEG_RESULTS[$i]}"
    done
    printf '\nChecks: %s passed, %s failed, %s skipped.\n' "$pass" "$fail" "$skipped"
    if [ "$fail" -eq 0 ] && [ "$skipped" -eq 0 ]; then
      printf '\nFailed: nothing. Every leg ran and every check passed.\n'
    else
      # printf --: a format opening with '- ' reads as an option to bash's
      # printf and emits NOTHING — a record whose Failed section silently
      # vanished is exactly the lie this file exists to make impossible.
      [ "$fail" -gt 0 ] && printf '\nFailed:\n'
      for line in "${findings[@]:-}"; do
        case "$line" in FAIL:*) printf -- '- %s\n' "$line" ;; esac
      done
      [ "$skipped" -gt 0 ] && printf '\nSkipped — these did NOT run, and this record is not evidence for them:\n'
      for line in "${findings[@]:-}"; do
        case "$line" in SKIP:*) printf -- '- %s\n' "$line" ;; esac
      done
    fi
    printf '\nThe isolation boundary was NOT asserted here: it is box'\''s drill'\''s\n'
    printf 'assertion (heavy-duty/box drill/drill.sh), joined to this record by the run ID.\n'
  } > "$out"
}

# =============================================================================
# Pre-flight — every refusal this run can see coming fires here, before
# anything is installed or any credential is spent. Args are validated BEFORE
# the root check (repo doctrine, bootstrap.sh:114 — so the refusals are
# testable without root, and a typo costs a re-type, never a re-ssh).
# =============================================================================
# Both refs EXPLICIT, or nothing runs. Defaulting either to main is exactly
# the #103 hazard this harness exists to refuse: "I drilled the release" must
# not quietly mean "I drilled whatever main was that afternoon".
if [ -z "$REF" ] || [ -z "$BOXREF" ]; then
  echo "drill: both refs must be pinned explicitly — a drill against an unstated ref is not evidence (#103):" >&2
  echo "  --rig-ref <ref>   (or RIG_REF)   the rig candidate, e.g. release/0.4.0   [got: ${REF:-<unset>}]" >&2
  echo "  --box-ref <ref>   (or BOX_REF)   the box that will ship with it          [got: ${BOXREF:-<unset>}]" >&2
  exit 2
fi

case "$REF" in
  refs/pull/*)
    echo "drill: --rig-ref cannot be a refs/pull/... ref — raw and archive URLs do not resolve GitHub PR refs. Push the candidate to a fork branch and pass that branch name with --rig-repo <fork-owner/rig> --rig-ref <branch>." >&2
    exit 2 ;;
esac

case "$ROLE" in
  staging-server|dev-server|control-plane-server|workload-server|runner-server) ;;
  *) echo "drill: --role $ROLE is not a machine role this drill can converge unattended" >&2; exit 2 ;;
esac

if { [ -n "$USERS_FILE" ] && [ -n "$USERS_FROM_GITHUB" ]; } ||
   { [ -z "$USERS_FILE" ] && [ -z "$USERS_FROM_GITHUB" ]; }; then
  echo "drill: exactly one of --users <path> or --users-from-github <handle> is required — leg 1 asserts operators converged" >&2
  exit 2
fi
[ -z "$USERS_FROM_GITHUB" ] || {
  [[ "$USERS_FROM_GITHUB" == "${USERS_FROM_GITHUB,,}" &&
     "$USERS_FROM_GITHUB" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
    echo "drill: --users-from-github must also be a valid rig username (lowercase letter or '_', then lowercase letters, digits, '_' or '-'; max 32)" >&2
    exit 2
  }
  [ "$USERS_FROM_GITHUB" != root ] || {
    echo "drill: --users-from-github root is reserved and cannot be an operator; use --users <path> with a non-root operator" >&2
    exit 2
  }
}

# `box shell` preserves SUDO_USER even though the effective uid is root. The
# users family correctly refuses identity changes from a non-admin invoker, so
# catch that entry-path trap before fetching keys or spending a tailnet key.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] \
    && ! id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx rig-admin; then
  echo "drill: SUDO_USER=$SUDO_USER is not in rig-admin, so bootstrap's users phase will refuse. Enter with 'incus exec <box> -- bash -l' or unset SUDO_USER before running the drill." >&2
  exit 2
fi

[ -z "$USERS_FILE" ] || [ -r "$USERS_FILE" ] || { echo "drill: cannot read users file: $USERS_FILE" >&2; exit 2; }

[ "$(id -u)" -eq 0 ] || { echo "drill: must run as root (bootstrap, Docker and db all require it) — ssh in as root on the throwaway machine" >&2; exit 1; }

# The tailnet join needs a key unless this machine already joined (a re-drill
# on the same throwaway). Caught here, not 10 apt-minutes into bootstrap.
if [ -z "${TS_AUTHKEY:-}" ]; then
  if ! { command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; }; then
    echo "drill: TS_AUTHKEY is unset and this machine has not joined a tailnet — leg 1's bootstrap will refuse. Mint a single-use TAGGED pre-auth key and export TS_AUTHKEY." >&2
    exit 2
  fi
fi

command -v curl >/dev/null 2>&1 || { echo "drill: curl is required (the pinned installs download over it)" >&2; exit 1; }

if [ -n "$USERS_FROM_GITHUB" ]; then
  GENERATED_USERS_FILE="$(mktemp)"
  trap 'rm -f "$GENERATED_USERS_FILE"' EXIT
  if ! GITHUB_KEYS="$(curl -fsSL "https://github.com/$USERS_FROM_GITHUB.keys")"; then
    echo "drill: could not fetch public keys from https://github.com/$USERS_FROM_GITHUB.keys" >&2
    exit 2
  fi
  printf '%s\n' "$GITHUB_KEYS" | render_github_users "$USERS_FROM_GITHUB" > "$GENERATED_USERS_FILE"
  [ -s "$GENERATED_USERS_FILE" ] || { echo "drill: GitHub user $USERS_FROM_GITHUB has no public SSH keys" >&2; exit 2; }
  USERS_FILE="$GENERATED_USERS_FILE"
fi

if [ "$YES" -ne 1 ]; then
  cat <<EOF
This will, ON THIS HOST ($(hostname)):
  · wipe any installed rig and reinstall $REPO@$REF from scratch
  · run 'rig bootstrap $ROLE --users $USERS_FILE' — sshd hardening, hostname
    change, tailnet join, box ($BOXREPO@$BOXREF) + its Incus stack — TWICE
    (the second run is the idempotence assertion)
  · install Debian's Docker package for the database round-trip
Only do this on a THROWAWAY machine you can format.
EOF
  [ -t 0 ] || { echo "drill: no TTY to confirm on — pass --yes if you mean it." >&2; exit 2; }
  printf 'Continue? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes) ;; *) echo "stopped."; exit 1 ;; esac
fi

phase "Pinned candidates"
RIG_SHA="$(ref_sha "$REPO" "$REF")"
BOX_SHA="$(ref_sha "$BOXREPO" "$BOXREF")"
inf "rig: $REPO@$REF (${RIG_SHA:-unresolved})"
inf "box: $BOXREPO@$BOXREF (${BOX_SHA:-unresolved})"
inf "run ID: $RUN_ID — drills sharing this substrate share it (drills/README.md)"

# =============================================================================
phase "Installing rig ($REPO@$REF) from scratch"
# =============================================================================
# The drill proves a tree from SCRATCH every run — a fresh machine, not a
# converged install — so any prior rig goes first (root's install lands at
# \$HOME/.local/share/rig with the /usr/local/bin symlink).
rm -rf "$HOME/.local/share/rig" /usr/local/bin/rig

if ! run_logged /tmp/drill-rig-install.log \
     env RIG_REPO="$REPO" RIG_REF="$REF" \
     bash -c "bash <(curl -fsSL \"https://raw.githubusercontent.com/$REPO/$REF/install.sh\")"; then
  echo "drill: rig's installer failed — tail of /tmp/drill-rig-install.log:" >&2
  tail -5 /tmp/drill-rig-install.log >&2
  exit 1
fi
command -v rig >/dev/null 2>&1 || { echo "drill: installer reported success but no 'rig' on PATH" >&2; exit 1; }

# ASSERT WHAT LANDED — the up-front ref assertion, fatal on mismatch.
RIG_TREE="$(tree_of "$(command -v rig)")"
assert_installed_from rig "$RIG_TREE" "$REPO@$REF" || exit 1
DRILL_VERSION="$(head -n1 "$RIG_TREE/VERSION" 2>/dev/null || echo unknown)"
ok "installed tree confirms: $REPO@$REF (version $DRILL_VERSION)"

# The rig-templates ref this candidate converges (#110), for the record: the
# env override when the drill was pointed somewhere, else the pin read from
# the INSTALLED tree — what actually landed, never this checkout's copy. A
# 40-hex ref IS its own SHA (the pin's normal shape); anything else resolves
# through ref_sha like the two candidates above.
if [ -z "$TPLREF" ]; then
  TPLREF="$(sed -n 's/^RIG_TEMPLATES_PIN=//p' "$RIG_TREE/commands/lib/templates.sh" 2>/dev/null | head -n1)"
  if [ -n "$TPLREF" ] &&
     [ -n "$(find "$RIG_TREE/templates@$TPLREF" -mindepth 2 -maxdepth 2 -type f -name template.env -print -quit 2>/dev/null)" ]; then
    TPL_SOURCE="snapshot"
  fi
fi
if [[ "$TPLREF" =~ ^[0-9a-f]{40}$ ]]; then
  TPL_SHA="${TPLREF:0:7}"
elif [ -n "$TPLREF" ]; then
  TPL_SHA="$(ref_sha "$TPLREPO" "$TPLREF")"
fi
inf "templates: $TPLREPO@${TPLREF:-unresolved} (${TPL_SHA:-unresolved}, $TPL_SOURCE)"
[ -n "$RECORD" ] || RECORD="$(default_record_path "$DRILL_VERSION")"

# =============================================================================
phase "Leg 1 — convergence: rig bootstrap $ROLE"
# =============================================================================
# BOX_REPO/BOX_REF ride the environment into bootstrap's host=yes box install,
# so the box that lands is the pinned candidate, not what bootstrap falls back
# to unexported (the BOX_RELEASE pin, since rig#103 landed).
export BOX_REPO="$BOXREPO" BOX_REF="$BOXREF"

t0=$SECONDS
if run_logged /tmp/drill-bootstrap-1.log rig bootstrap "$ROLE" --users "$USERS_FILE"; then
  ok "rig bootstrap $ROLE --users … exited 0  ($((SECONDS - t0))s)"
  BOOTSTRAP_OK=1
else
  no "rig bootstrap $ROLE FAILED — tail: $(tail -3 /tmp/drill-bootstrap-1.log | tr '\n' ' ')"
  BOOTSTRAP_OK=0
fi

MARKER_LINE="$(cat "${RIG_ROLE_MARKER:-/etc/rig/role}" 2>/dev/null || true)"
if [ "$BOOTSTRAP_OK" -eq 1 ]; then
  # The role, asserted on EFFECTIVE state — the marker, the daemon's resolved
  # config, the netmap's granted tags — never on what was requested (the
  # sshd-first-wins lesson, lib/sshd.sh:63-70).
  case "$MARKER_LINE" in
    "role=$ROLE "*) ok "role marker: $MARKER_LINE" ;;
    *) no "role marker is '$MARKER_LINE' — expected role=$ROLE …" ;;
  esac
  sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' \
    && ok "sshd -T resolves passwordauthentication no (the hardening took)" \
    || no "sshd still resolves password auth — the 00-rig.conf drop-in is not winning"
  ts_tags="$(tailscale status --json 2>/dev/null | tr -d '\n ' | grep -o '"Tags":\[[^]]*\]' | head -n1)"
  if [ -n "$ts_tags" ] && [ "$ts_tags" != '"Tags":[]' ]; then
    ok "tailnet joined, tagged: $ts_tags"
  else
    no "tailnet join did not leave a tagged node (got: ${ts_tags:-nothing}) — bootstrap's verify should have refused this"
  fi
  grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null \
    && ok "unattended-upgrades enabled" || no "20auto-upgrades missing or wrong"
  grep -q "converged_by=$DRILL_VERSION" "${RIG_MANIFEST:-/etc/rig/manifest}" 2>/dev/null \
    && ok "manifest: converged_by=$DRILL_VERSION" || no "manifest does not name $DRILL_VERSION as the converging rig"
  users_bad=""
  while read -r u state; do
    [ "$state" = active ] || continue
    id -u "$u" >/dev/null 2>&1 || { users_bad="$users_bad $u(no-account)"; continue; }
    uhome="$(getent passwd "$u" | cut -d: -f6)"
    [ -s "$uhome/.ssh/authorized_keys" ] || users_bad="$users_bad $u(no-keys)"
  done < <(cat "${DRILL_LEDGER:-/etc/rig/users}" 2>/dev/null)
  # NOT 'grep -c … || echo 0': grep -c already prints 0 on no match (and then
  # exits 1), so the fallback would emit a second line into the substitution.
  n_users="$(grep -c ' active$' "${DRILL_LEDGER:-/etc/rig/users}" 2>/dev/null)" || true
  n_users="${n_users:-0}"
  [ -z "$users_bad" ] && [ "$n_users" -gt 0 ] \
    && ok "operators converged: $n_users active, accounts and keys present" \
    || no "operators NOT converged:${users_bad:- ledger empty}"
  leg "convergence — bootstrap $ROLE reaches its role" \
    "$([ "$fail" -eq 0 ] && echo "PASS ($((SECONDS - t0))s)" || echo "FAIL — see Failed below")"

  # --- idempotence: the claim this drill exists to make ----------------------
  # Capture, re-run, capture, diff. Mechanically — never "watched it not
  # obviously break". An empty diff IS the definition of converged.
  phase "Leg 1 — idempotence: the re-run must change nothing"
  pre="$(mktemp)"; post="$(mktemp)"
  capture_state "$pre"
  t0=$SECONDS
  if run_logged /tmp/drill-bootstrap-2.log rig bootstrap "$ROLE" --users "$USERS_FILE"; then
    ok "second bootstrap exited 0  ($((SECONDS - t0))s)"
  else
    no "second bootstrap FAILED — tail: $(tail -3 /tmp/drill-bootstrap-2.log | tr '\n' ' ')"
  fi
  capture_state "$post"
  if statediff="$(diff -u "$pre" "$post")"; then
    ok "re-converge is a no-op: the state diff is empty"
    leg "re-converge (idempotence)" "clean, no changes"
  else
    dlines="$(printf '%s\n' "$statediff" | grep -c '^[+-][^+-]')"
    no "re-converge CHANGED the box — $dlines state line(s) differ:"
    printf '%s\n' "$statediff" | sed 's/^/          /'
    leg "re-converge (idempotence)" "DIRTY — $dlines state line(s) changed on the re-run"
  fi
  rm -f "$pre" "$post"
else
  leg "convergence — bootstrap $ROLE reaches its role" "FAIL — bootstrap exited non-zero"
  skip "idempotence not asserted — the first converge already failed, a re-run diff would measure noise"
  leg "re-converge (idempotence)" "SKIPPED — first converge failed"
fi

# =============================================================================
phase "--host yes — the box that will ship"
# =============================================================================
# The assertions #105 settles this leg at: the installer ran, INSTALLED_FROM
# matches the requested BOX_REF, setup-host exited clean, the stack it claims
# stands. Then it STOPS. Not one isolation probe: two records that both claim
# the trust boundary will eventually disagree with no tiebreaker, and a
# partial isolation check reads — months later, in a record — as though the
# boundary was drilled (box#153's shape through a different door). Resist
# adding "just one" probe here; that is box's drill's whole job.
case "$MARKER_LINE" in
  *"host=yes"*)
    if command -v box >/dev/null 2>&1; then
      ok "box CLI on PATH"
      BOX_TREE="$(tree_of "$(command -v box)")"
      # Fatal, like rig's own: a wrong box under --host yes poisons the pair.
      assert_installed_from box "$BOX_TREE" "$BOXREPO@$BOXREF" || exit 1
      ok "installed box confirms: $BOXREPO@$BOXREF"
      if box doctor >/dev/null 2>&1; then
        ok "box doctor passes — setup-host converged; the host stack stands (box's own effective-state verdict)"
        leg "--host yes: pinned box installed, host stack up" "PASS — $BOXREPO@$BOXREF, box doctor clean"
      else
        no "box is installed but 'box doctor' does not pass — the host stack is unproven (run 'box doctor' for box's verdict)"
        leg "--host yes: pinned box installed, host stack up" "FAIL — box doctor does not pass"
      fi
    else
      no "no 'box' on PATH after a host=yes bootstrap — the box install did not take (bootstrap warns rather than dies there; the drill does not)"
      leg "--host yes: pinned box installed, host stack up" "FAIL — box CLI never landed"
    fi
    inf "isolation NOT asserted here — deliberately. The VM trust boundary is box's"
    inf "assertion, made by box's own drill (~85 probes); this leg stops at 'the pinned"
    inf "box installed and its host stack stands'. The records join on the run ID."
    ;;
  *)
    skip "--host yes assertions: role $ROLE left host=no (marker: ${MARKER_LINE:-absent})"
    leg "--host yes: pinned box installed, host stack up" "SKIPPED — this role does not host VMs"
    ;;
esac

# =============================================================================
phase "Preparing Docker for Leg 2"
# =============================================================================
# The throwaway starts without Docker. Install the Debian-owned package
# directly: this is drill scaffolding for the db evidence, not a rig command.
if run_logged /tmp/drill-docker.log bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y docker.io
  systemctl enable --now docker
'; then
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
    && ok "Docker installed directly and the daemon answers" \
    || no "Docker package installation exited 0 but the daemon does not answer"
else
  no "Docker prerequisite FAILED — tail: $(tail -3 /tmp/drill-docker.log | tr '\n' ' ')"
fi

# =============================================================================
phase "Leg 2 — db dump/restore round-trip (test/db-integration.sh)"
# =============================================================================
# Driven from the INSTALLED tree — the drill exercises what shipped, not the
# checkout this script happens to sit in. The leg's skip contract is the
# script's own (loud, reasoned, exit 0) and classify_leg keeps it a SKIP:
# counted, rendered distinctly, named in the record — never a pass.
db_out="$(mktemp)"
bash "$RIG_TREE/test/db-integration.sh" >"$db_out" 2>&1
db_rc=$?
case "$(classify_leg "$db_rc" "$db_out")" in
  pass)
    db_numbers="$(tail -1 "$db_out")"
    ok "db round-trip: $db_numbers"
    leg "test/db-integration.sh" "PASS — $db_numbers"
    ;;
  skip)
    db_reason="$(grep -m1 '^skip:' "$db_out")"
    skip "db round-trip did not run — $db_reason"
    leg "test/db-integration.sh" "SKIPPED — ${db_reason#skip: }"
    ;;
  fail)
    no "db round-trip FAILED (exit $db_rc) — tail: $(tail -3 "$db_out" | tr '\n' ' ')"
    leg "test/db-integration.sh" "FAIL — exit $db_rc"
    ;;
esac
rm -f "$db_out"

# =============================================================================
phase "Summary"
# =============================================================================
printf '  %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
if [ "${#findings[@]}" -gt 0 ]; then
  echo
  printf '  %s\n' "${findings[@]}"
fi

mkdir -p "$(dirname "$RECORD")"
emit_record "$RECORD"
publish_record "$RECORD"
[ "$fail" -eq 0 ]
