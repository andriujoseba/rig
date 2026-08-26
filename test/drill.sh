#!/usr/bin/env bash
# test/drill.sh — the drill harness's HONESTY, proven without hardware.
#
# drill/drill.sh is the instrument (#105), so what this suite tests is the
# instrument itself: the refusals, the classifications, the capture-and-diff
# that decides idempotence, and the record emitter — the parts whose lies
# would be believed, months later, by a reader of drills/<version>.md. The
# two-leg live run on a real Debian machine is #107's exercise, not this
# file's: nothing here needs root, Docker, a tailnet or the network.
#
# Extraction pattern is test/release.sh's: the functions under test are
# awk-extracted from drill/drill.sh and driven against fixtures, so the tests
# exercise the shipped bytes, and the extraction check itself guards the awk
# against a drifted function boundary.
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
check() {
  local desc="$1" want="$2" substr="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$substr" ] && ! printf '%s' "$out" | grep -qF -e "$substr"; then
    echo "FAIL: $desc — output missing '$substr'"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $desc"; PASS=$((PASS + 1))
}

# refute <desc> <substr> <file> — the file must NOT contain the substring.
refute() {
  if grep -qF -e "$2" "$3"; then
    echo "FAIL: $1 — found forbidden '$2'"
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $1"; PASS=$((PASS + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the functions under test, extracted -------------------------------------
FNS="$WORK/drill-fns.sh"
for fn in tree_of assert_installed_from classify_leg capture_state default_record_path render_github_users publish_record emit_record; do
  awk "/^${fn}\(\) \{/,/^\}/" "$ROOT/drill/drill.sh" >> "$FNS"
done
for fn in tree_of assert_installed_from classify_leg capture_state default_record_path render_github_users publish_record emit_record; do
  check "extraction guards the awk: ${fn}() landed" 0 "${fn}() {" grep -F "${fn}() {" "$FNS"
done
# shellcheck source=/dev/null
. "$FNS"

# =============================================================================
# tree_of — the versioned tree behind a CLI's symlink chain
# =============================================================================
IR="$WORK/install"; mkdir -p "$IR/versions/1.2.3/bin"
: > "$IR/versions/1.2.3/bin/rig"
ln -s "versions/1.2.3" "$IR/current"
mkdir -p "$WORK/bin"
ln -s "$IR/current/bin/rig" "$WORK/bin/rig"
check "tree_of resolves a current-symlink chain to versions/<v>" 0 "$IR/versions/1.2.3" \
  tree_of "$WORK/bin/rig"
ln -s "$IR/gone/bin/rig" "$WORK/bin/dangling"
check "tree_of refuses a dangling chain — a tree that is not there is not a tree" 1 "" \
  tree_of "$WORK/bin/dangling"

# =============================================================================
# assert_installed_from — the up-front ref refusal, naming both refs
# =============================================================================
TREE="$WORK/tree-main"; mkdir -p "$TREE"
printf 'heavy-duty/rig@main\n' > "$TREE/INSTALLED_FROM"
check "matching INSTALLED_FROM passes silently" 0 "" \
  assert_installed_from rig "$TREE" "heavy-duty/rig@main"
check "a mismatch refuses (the #103 hazard: asked release, got main)" 1 "FATAL" \
  assert_installed_from rig "$TREE" "heavy-duty/rig@release/9.9.9"
check "…the refusal names the ref that was ASKED for" 1 "heavy-duty/rig@release/9.9.9" \
  assert_installed_from rig "$TREE" "heavy-duty/rig@release/9.9.9"
check "…and the ref that actually LANDED" 1 "heavy-duty/rig@main" \
  assert_installed_from rig "$TREE" "heavy-duty/rig@release/9.9.9"
check "an unreadable INSTALLED_FROM refuses too — absence is not a match" 1 "<unreadable>" \
  assert_installed_from rig "$WORK/no-such-tree" "heavy-duty/rig@main"

# =============================================================================
# classify_leg — a loud skip is a SKIP, never a pass (box#153's defect class)
# =============================================================================
printf 'skip: docker not installed — nothing to exercise\n' > "$WORK/out-skip"
printf 'ok: seeded\nok: restored\n---\n14 passed, 0 failed\n' > "$WORK/out-pass"
printf 'FAIL: restore blew up\n' > "$WORK/out-fail"
check "exit 0 + 'skip:' line classifies as skip" 0 "skip" classify_leg 0 "$WORK/out-skip"
check "exit 0, no skip line, classifies as pass" 0 "pass" classify_leg 0 "$WORK/out-pass"
check "non-zero exit classifies as fail" 0 "fail" classify_leg 1 "$WORK/out-fail"
check "a skip line cannot rescue a non-zero exit (fail wins)" 0 "fail" \
  classify_leg 1 "$WORK/out-skip"

# =============================================================================
# capture_state + diff — the idempotence verdict's machinery. The claim in
# #105's acceptance criteria: the assertion is a REAL diff of captured state,
# and it FAILS when convergence is broken — demonstrated here, mechanically,
# on every CI run, by breaking the state between two captures.
# =============================================================================
FIX="$WORK/fix"; mkdir -p "$FIX/sudoers.d"
printf 'role=staging-server root-door=open host=yes join=authkey\n' > "$FIX/role"
printf 'schema=1\nbootstrapped_by=9.9.9\nbootstrapped_at=T\nconverged_by=9.9.9\nconverged_at=T\n' > "$FIX/manifest"
printf 'dan active\nghost revoked\n' > "$FIX/ledger"
printf 'APT::Periodic::Update-Package-Lists "1";\n' > "$FIX/autoup"
printf '127.0.0.1 localhost\n127.0.1.1\tstaging-server\n' > "$FIX/hosts"
printf 'nosuchdrilluser ALL=(ALL) NOPASSWD:ALL\n' > "$FIX/sudoers.d/00-rig-nosuch"
# A stubbed sshd, so the effective-config section is exercised rather than
# skipped on a box with no daemon (repo precedent: test/release.sh's curl).
STUB="$WORK/stub"; mkdir -p "$STUB"
# The single-quoted $SSHD_FIXTURE is the STUB's expansion, not this shell's.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ncat "$SSHD_FIXTURE"\n' > "$STUB/sshd"; chmod +x "$STUB/sshd"
printf 'passwordauthentication no\npermitrootlogin prohibit-password\n' > "$FIX/sshd-T"

cap() {   # cap <outfile> — capture_state against the fixture set
  RIG_ROLE_MARKER="$FIX/role" RIG_MANIFEST="$FIX/manifest" \
  DRILL_LEDGER="$FIX/ledger" DRILL_AUTOUPGRADES="$FIX/autoup" \
  DRILL_ETC_HOSTS="$FIX/hosts" DRILL_SUDOERS_DIR="$FIX/sudoers.d" \
  SSHD_FIXTURE="$FIX/sshd-T" PATH="$STUB:$PATH" \
  bash -c '. "$1"; capture_state "$2"' _ "$FNS" "$2" 2>/dev/null
  :
}
# cap runs capture_state in a child bash so the PATH stub cannot leak into
# this harness; $2 arrives as the capture's outfile.
cap out "$WORK/cap1"
cap out "$WORK/cap2"
check "two captures over untouched state diff EMPTY (the converged verdict)" 0 "" \
  diff -u "$WORK/cap1" "$WORK/cap2"
check "the capture reads the fixtures, not the machine (marker line present)" 0 "role=staging-server" \
  grep -o 'role=staging-server[^"]*' "$WORK/cap1"
check "…the sshd section captured the effective config" 0 "passwordauthentication no" \
  cat "$WORK/cap1"
check "…a ledger user with no account reads as one, deterministically" 0 "(no account)" \
  cat "$WORK/cap1"

# Break convergence: the re-run "changed" the role marker and root's door.
printf 'role=staging-server root-door=closed host=yes join=authkey\n' > "$FIX/role"
printf 'passwordauthentication yes\npermitrootlogin prohibit-password\n' > "$FIX/sshd-T"
cap out "$WORK/cap3"
check "a broken convergence makes the diff NON-empty — the assertion can fail" 1 "root-door=closed" \
  diff -u "$WORK/cap1" "$WORK/cap3"
check "…and the diff names the drifted sshd keyword, not just 'differs'" 1 "passwordauthentication yes" \
  diff -u "$WORK/cap1" "$WORK/cap3"

# =============================================================================
# emit_record — the record is drills/README.md's shape, and it cannot lie:
# a failed run still emits, a skipped leg is named, no clean-sweep reading.
# =============================================================================
emit() {   # emit <outfile> — emit_record with the harness globals staged
  DRILL_VERSION="9.9.9" RUN_ID="drill-2026-01-01-a" \
  REF="release/9.9.9" BOXREF="release/0.4.0" RIG_SHA="5d6e7f8" BOX_SHA="1a2b3c4" \
  TPLREPO="heavy-duty/rig-templates" TPLREF="9f8e7d6c5b4a39281706f5e4d3c2b1a098765432" TPL_SHA="9f8e7d6" TPL_SOURCE="snapshot" \
  bash -c '
    . "$1"
    pass=12 fail=1 skipped=1
    findings=("FAIL: Docker prerequisite did not start" "SKIP: db round-trip did not run — no Docker daemon" "NOTE: something worth a line")
    LEG_NAMES=("convergence — bootstrap staging-server reaches its role" "re-converge (idempotence)" "test/db-integration.sh")
    LEG_RESULTS=("PASS (312s)" "clean, no changes" "SKIPPED — no Docker daemon")
    emit_record "$2"
  ' _ "$FNS" "$2"
}
emit out "$WORK/record.md"
check "record: the version-and-date heading" 0 "# Release drill — 9.9.9 — " head -1 "$WORK/record.md"
check "record: the run ID that joins the family's records" 0 "Run ID: drill-2026-01-01-a" cat "$WORK/record.md"
check "record: both pinned refs with their SHAs" 0 "rig@5d6e7f8 (RIG_REF=release/9.9.9)" cat "$WORK/record.md"
check "record: …box's too" 0 "box@1a2b3c4 (BOX_REF=release/0.4.0)" cat "$WORK/record.md"
check "record: the template registry SHA and actual source ride alongside the pair (#110/#153)" 0 "rig-templates@9f8e7d6 (ref 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432, snapshot)" cat "$WORK/record.md"
check "record: one table row per leg, result verbatim" 0 "| re-converge (idempotence) | clean, no changes |" cat "$WORK/record.md"
check "record: the numbers, skips counted apart from passes" 0 "12 passed, 1 failed, 1 skipped" cat "$WORK/record.md"
check "record: a FAILED run still names what failed (evidence, not success)" 0 "FAIL: Docker prerequisite did not start" cat "$WORK/record.md"
check "record: a skipped leg is stated as NOT run, by name" 0 "SKIP: db round-trip" cat "$WORK/record.md"
check "record: the skip section says the record is not evidence for it" 0 "not evidence" cat "$WORK/record.md"
check "record: the isolation boundary is named as box's, in words" 0 "NOT asserted here" cat "$WORK/record.md"
refute "record with a skip cannot read as a clean sweep" "Failed: nothing" "$WORK/record.md"
refute "notes are findings for the log, not failures for the record" "NOTE: something" "$WORK/record.md"

# The all-green shape: says so plainly, and only then.
DRILL_VERSION="9.9.9" RUN_ID="drill-2026-01-01-a" \
REF="release/9.9.9" BOXREF="release/0.4.0" RIG_SHA="5d6e7f8" BOX_SHA="1a2b3c4" \
bash -c '
  . "$1"
  pass=20 fail=0 skipped=0
  findings=()
  LEG_NAMES=("convergence" "re-converge (idempotence)")
  LEG_RESULTS=("PASS" "clean, no changes")
  emit_record "$2"
' _ "$FNS" "$WORK/record-green.md"
check "an all-green record says every leg ran and passed" 0 "Every leg ran and every check passed" \
  cat "$WORK/record-green.md"
check "the default record path is independent of a checkout" 0 "/root/drills/9.9.9.md" \
  default_record_path 9.9.9
printf 'ssh-ed25519 AAAAone dan@laptop\nssh-ed25519 AAAAtwo dan@desktop\n' > "$WORK/github.keys"
# The positional parameters belong to the child bash, intentionally.
# shellcheck disable=SC2016
check "GitHub keys render one admin,box ledger line per key" 0 "danmt admin,box ssh-ed25519 AAAAtwo" \
  bash -c '. "$1"; render_github_users danmt < "$2"' _ "$FNS" "$WORK/github.keys"
publish_record "$WORK/record-green.md" > "$WORK/published-record"
check "the final record payload prints its path" 0 "record written: $WORK/record-green.md" \
  cat "$WORK/published-record"
check "the final record payload includes the full record" 0 "Every leg ran and every check passed" \
  cat "$WORK/published-record"

# =============================================================================
# the shipped script itself
# =============================================================================
# Arg refusals fire before the root check (repo doctrine, bootstrap.sh:114),
# which is what makes them provable here without a throwaway machine.
check "drill.sh refuses to run without BOTH refs pinned (#103)" 2 "--box-ref" \
  env -u RIG_REF -u BOX_REF bash "$ROOT/drill/drill.sh" --rig-ref release/9.9.9 --yes
drill_help_has_retired_flag() { bash "$ROOT/drill/drill.sh" --help | grep -q -- '--runner-'; }
drill_help_has_retired_coolify_flag() { bash "$ROOT/drill/drill.sh" --help | grep -q -- '--coolify-version'; }
drill_help_spills_internal_commentary() {
  bash "$ROOT/drill/drill.sh" --help | grep -q "probe && ok"
}
drill_process_substitution_help() {
  bash <(cat "$ROOT/drill/drill.sh") --help
}
drill_leg_count() { grep -Ec '^phase "Leg [0-9]+' "${1:-$ROOT/drill/drill.sh}"; }
docker_source_precedes_db() {
  local docker_line db_line
  docker_line="$(grep -nF 'apt-get install -y docker.io' "$ROOT/drill/drill.sh" | cut -d: -f1)"
  db_line="$(grep -nF 'phase "Leg 2 — db dump/restore round-trip' "$ROOT/drill/drill.sh" | cut -d: -f1)"
  [ -n "$docker_line" ] && [ -n "$db_line" ] && [ "$docker_line" -lt "$db_line" ]
}
DRILL_LEG_COUNT_FIXTURE="$WORK/three-numbered-legs.sh"
printf '%s\n' \
  'phase "Leg 1 — one"' \
  'phase "Leg 2 — two"' \
  'phase "Leg 3 — three"' > "$DRILL_LEG_COUNT_FIXTURE"
check "drill.sh help names no retired runner flag" 1 "" drill_help_has_retired_flag
check "drill.sh help names no retired Coolify flag" 1 "" drill_help_has_retired_coolify_flag
check "drill.sh help ends before internal commentary" 1 "" drill_help_spills_internal_commentary
check "drill.sh help works through process substitution" 0 "THROWAWAY" \
  drill_process_substitution_help
check "drill.sh runs exactly two numbered legs" 0 "2" drill_leg_count
check "drill leg counter sees a synthetic third leg" 0 "3" \
  drill_leg_count "$DRILL_LEG_COUNT_FIXTURE"
check "drill installs Docker directly before the db leg" 0 "" docker_source_precedes_db
check "…and the refusal shows which ref is missing" 2 "<unset>" \
  env -u RIG_REF -u BOX_REF bash "$ROOT/drill/drill.sh" --rig-ref release/9.9.9 --yes
check "a tenant role is refused — the drill converges machines, not guests" 2 "not a machine role" \
  bash "$ROOT/drill/drill.sh" --rig-ref r --box-ref b --role claude-box --yes
check "no users source is a refusal" 2 "exactly one of --users <path> or --users-from-github <handle>" \
  bash "$ROOT/drill/drill.sh" --rig-ref r --box-ref b --yes
check "both users sources are refused" 2 "exactly one of --users <path> or --users-from-github <handle>" \
  bash "$ROOT/drill/drill.sh" --rig-ref r --box-ref b --users "$WORK/no-such-users" --users-from-github danmt --yes
check "an unreadable users file dies before anything is spent" 2 "cannot read users file" \
  bash "$ROOT/drill/drill.sh" --rig-ref r --box-ref b --users "$WORK/no-such-users" --yes
check "a GitHub users handle must also be a valid rig username" 2 "valid rig username" \
  bash "$ROOT/drill/drill.sh" --rig-ref r --box-ref b --users-from-github BadHandle --yes
check "root is refused as a GitHub-derived operator during pre-flight" 2 "root is reserved" \
  bash "$ROOT/drill/drill.sh" --rig-ref r --box-ref b --users-from-github root --yes
check "a PR ref is refused before install and names the fork-branch form" 2 "fork branch" \
  bash "$ROOT/drill/drill.sh" --rig-ref refs/pull/191/head --box-ref b --users "$WORK/no-such-users" --yes
check "a non-admin SUDO_USER is refused before its users source is read" 2 "incus exec <box> -- bash -l" \
  env SUDO_USER=dev bash "$ROOT/drill/drill.sh" --rig-ref r --box-ref b --users "$WORK/no-such-users" --yes
check "the SUDO_USER refusal also names the environment fix" 2 "unset SUDO_USER" \
  env SUDO_USER=dev bash "$ROOT/drill/drill.sh" --rig-ref r --box-ref b --users "$WORK/no-such-users" --yes
check "an unknown flag dies loudly, exit 2" 2 "unknown option" \
  bash "$ROOT/drill/drill.sh" --frobnicate
check "--help prints the header and exits 0" 0 "THROWAWAY" \
  bash "$ROOT/drill/drill.sh" --help

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
