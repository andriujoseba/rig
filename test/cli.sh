#!/usr/bin/env bash
# Dependency-free CLI assertions. Run: bash test/cli.sh
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
# Runs cmd, asserts exit code and (if non-empty) that combined output
# contains want_substr.
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

check "no args shows usage, exit 2"      2 "usage:" "$ROOT/bin/rig"
check "--help exits 0"                   0 "usage:" "$ROOT/bin/rig" --help
check "help exits 0"                     0 "usage:" "$ROOT/bin/rig" help
check "unknown command exits 2"          2 "unknown command" "$ROOT/bin/rig" frobnicate
check "bare coolify shows usage, exit 2" 2 "usage:" "$ROOT/bin/rig" coolify

check "bootstrap: role required, exit 2"   2 "role required"  "$ROOT/commands/bootstrap.sh"
check "bootstrap: --help exits 0"          0 "usage:"         "$ROOT/commands/bootstrap.sh" --help
check "bootstrap: unknown role exits 2"    2 "unknown role"   "$ROOT/commands/bootstrap.sh" potato
check "bootstrap: unknown flag exits 2"    2 "unknown flag"   "$ROOT/commands/bootstrap.sh" workload-server --nope
check "bootstrap: hostname needs value"    2 "needs a value"  "$ROOT/commands/bootstrap.sh" workload-server --hostname
# --ts-tag is REMOVED, not demoted: the tag now comes from the pre-auth key and
# rig verifies the GRANTED tag after join. The old runner-refuses-tag:server test
# asserted the request-time refusal THROUGH this flag; that policy now lives on
# the EFFECTIVE tag and needs a real tailnet, so it belongs to the rehearsal, not
# here. What this harness CAN prove is that the flag dies with a message pointing
# at the key (exit 2, a usage error), rather than an "unknown flag" that would
# leave an operator guessing where the tag went — value present or absent.
check "bootstrap: --ts-tag is removed (with value), exit 2" 2 "comes from the pre-auth key" \
  "$ROOT/commands/bootstrap.sh" runner-server --ts-tag tag:server
check "bootstrap: --ts-tag is removed (no value), exit 2"   2 "comes from the pre-auth key" \
  "$ROOT/commands/bootstrap.sh" runner-server --ts-tag
# staging-box is a box TENANT role (the guest, not the VM host), and it
# never joins the tailnet — but --ts-tag on it must still die with a story,
# not an "unknown flag": scripts from its trait-preset life may pass it, and
# the message must say where both the tag AND the join went.
check "bootstrap: staging-box + removed --ts-tag exits 2" 2 "never join the tailnet" \
  "$ROOT/commands/bootstrap.sh" staging-box --ts-tag tag:server
# The VM-HOST shape has a named role again (staging-server, #76), but it is
# still not one of the two the control plane manages, so the catch-all
# tag:server refusal must own it. Grep-pinned so a deleted guard cannot ship
# green (repo precedent: the login-path refusal below).
check "bootstrap: the catch-all tag:server refusal is present" 0 "" \
  grep -q "Only control-plane-server and workload-server are managed by the control plane" "$ROOT/commands/bootstrap.sh"
# ...and staging-server must NOT have slipped into the allow-list arm beside
# control-plane-server|workload-server. A new preset silently landing there
# would extend every server grant to a VM host, which is the exact shape the
# refusal exists to prevent — and nothing else in the suite would notice.
check "bootstrap: staging-server is not in the tag:server allow-list" 1 "" \
  grep -qE '^ *control-plane-server\|workload-server\)[^#]*staging-server' "$ROOT/commands/bootstrap.sh"

# --- the role taxonomy (#76): -server names the family, and it was a hard cut -
# Every machine role carries the suffix; custom and workstation deliberately do
# not. Proven by reaching the ROOT CHECK, which is the last thing before the
# converge and therefore proof the name resolved to a preset.
if [ "$(id -u)" -ne 0 ]; then
  for r in control-plane-server workload-server runner-server staging-server dev-server; do
    check "bootstrap: role $r resolves" 1 "must run as root" \
      env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" "$r" --no-users
  done
fi
# THE HARD CUT. No aliases: the pre-#76 names are gone, and must fail as
# UNKNOWN rather than quietly resolving to anything. Asserted per name because
# an alias accidentally left in for one role is exactly the shape that survives
# review — the taxonomy reads as complete while one old name still works.
# 'staging' is deliberately absent HERE: it is a TENANT name, and its own hard
# cut is asserted in the tenant section below, at both entrypoints.
for r in control-plane workload runner dev; do
  check "bootstrap: the pre-#76 name '$r' is gone (hard cut)" 2 "unknown role" \
    "$ROOT/commands/bootstrap.sh" "$r"
done
# ...but the two roles that legitimately carry no suffix must NOT have been
# swept up in the rename. This is the inverse error and it fails silently: a
# workstation that stopped resolving would only surface at someone's laptop.
check "bootstrap: workstation keeps its bare name" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workstation
check "bootstrap: custom keeps its bare name" 2 "--hostname" \
  "$ROOT/commands/bootstrap.sh" custom --root-door open --host no --join authkey
# NOTHING may still TELL an operator to run a pre-#76 role. The rename is a
# hard cut, so a next-step string, a usage line or a refusal that still recites
# a bare role name is a command that fails when someone copy-pastes it — and it
# fails later and further from the cause than a broken flag would, because it
# fails on a different box, minutes after this run reported success. The tenant
# script is the one that emits the staging guest's workload-join next step, so
# it is where this bites first (caught in review on #80, fixed here where the
# rename actually happens). Swept across every shipped script rather than
# asserted at the one known site: the next instance of this will be somewhere
# else, and a site-specific check would not see it.
check "roles: no shipped script tells an operator to run a pre-#76 role name" 1 "" \
  grep -rnE "rig bootstrap (control-plane|workload|runner|dev)( |'|\"|$)" \
    "$ROOT/bin/rig" "$ROOT/commands/"
# --- traits: roles are presets, every trait individually settable (#26) -----
check "bootstrap: unknown role still exits 2"    2 "unknown role" "$ROOT/commands/bootstrap.sh" potato
check "bootstrap: bad --root-door value exits 2" 2 "closed|open" "$ROOT/commands/bootstrap.sh" workload-server --root-door potato
check "bootstrap: bad --host value exits 2"      2 "yes|no"       "$ROOT/commands/bootstrap.sh" workload-server --host maybe
check "bootstrap: bad --join value exits 2"      2 "authkey|login" "$ROOT/commands/bootstrap.sh" workload-server --join carrier-pigeon
check "bootstrap: custom without --hostname exits 2" 2 "--hostname" \
  "$ROOT/commands/bootstrap.sh" custom --root-door open --host no --join authkey
check "bootstrap: custom without traits exits 2" 2 "--root-door" "$ROOT/commands/bootstrap.sh" custom --hostname box1
# workstation is join=login by preset: a set TS_AUTHKEY is a usage error, and it
# must die BEFORE the root check — provable non-root, which also proves the
# preset actually landed.
check "bootstrap: workstation + TS_AUTHKEY exits 2" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workstation
# A trait override changes derived behavior, provable non-root: dev is
# join=authkey (TS_AUTHKEY fine → falls through to the root check), but
# --join login flips it into the TS_AUTHKEY refusal.
check "bootstrap: dev --join login + TS_AUTHKEY exits 2" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" dev-server --join login
# The login-path inverted assertion needs a real tailnet; grep the refusal so a
# deleted guard cannot ship green (repo precedent: staging/runner tag greps).
check "bootstrap: login-path tagged refusal is present" 0 "" \
  grep -q "join=login expects a user-owned, untagged node" "$ROOT/commands/bootstrap.sh"
# Re-running with join=authkey on a box that was legitimately login-joined
# (untagged BY DESIGN) lands in verify_effective_tag's untagged branch. Backing
# out a join this run did not perform would tear down a user-owned workstation;
# the already-joined path must refuse WITHOUT logout and name both repairs.
# Needs a real tailnet to exercise, so grep the keep-mode die instead.
check "bootstrap: already-joined untagged refusal keeps the join" 0 "" \
  grep -q "joined but UNTAGGED" "$ROOT/commands/bootstrap.sh"
# verify_user_owned must fail CLOSED on a stalled backend: empty tags is its
# SUCCESS signal, so a 30s poll that never saw Running would wave a tagged node
# through as user-owned. Grep the timeout die (same real-tailnet excuse).
check "bootstrap: login verify fails closed on a stalled backend" 0 "" \
  grep -q "could not verify the join is user-owned" "$ROOT/commands/bootstrap.sh"
# The marker is the traits' ground truth for rig users; assert the write exists.
check "bootstrap: role marker write is present" 0 "" \
  grep -q "/etc/rig/role" "$ROOT/commands/bootstrap.sh"
check "bootstrap: role marker records join provenance" 0 "join-by=%s" \
  grep -F "join-by=%s" "$ROOT/commands/bootstrap.sh"
check "bootstrap: both first-join paths record join-by=rig" 0 "2" \
  grep -c "^[[:space:]]*JOIN_BY=rig$" "$ROOT/commands/bootstrap.sh"
check "bootstrap: already-joined path defaults to join-by=preexisting" 0 "JOIN_BY=preexisting" \
  grep -F "JOIN_BY=preexisting" "$ROOT/commands/bootstrap.sh"

# Drive the narrow inverse end to end. Every refusal also asserts the tailscale
# shim was NOT called: exit status alone would miss the destructive regression.
UNDO_FIX="$(mktemp -d)"
UNDO_BIN="$UNDO_FIX/bin"
UNDO_MARKER="$UNDO_FIX/role"
UNDO_RUNNER="$UNDO_FIX/runner"
UNDO_CALLS="$UNDO_FIX/tailscale.calls"
mkdir -p "$UNDO_BIN" "$UNDO_RUNNER"
cat > "$UNDO_BIN/tailscale" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UNDO_CALLS"
if [ "${TAILSCALE_LOGOUT_FAIL:-0}" = 1 ]; then exit 1; fi
SH
cat > "$UNDO_BIN/id" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then printf '0\n'; else exec /usr/bin/id "$@"; fi
SH
chmod +x "$UNDO_BIN/tailscale" "$UNDO_BIN/id"
undo() {
  env PATH="$UNDO_BIN:$PATH" UNDO_CALLS="$UNDO_CALLS" \
    RIG_ROLE_MARKER="$UNDO_MARKER" RIG_RUNNER_DIR="$UNDO_RUNNER" \
    "$ROOT/bin/rig" bootstrap --undo
}
undo_untouched() {
  : > "$UNDO_CALLS"
  if undo >"$UNDO_FIX/undo.out" 2>&1; then return 1; fi
  [ ! -s "$UNDO_CALLS" ]
}
rm -f "$UNDO_MARKER"
check "bootstrap --undo: no marker refuses without touching tailnet" 0 "" undo_untouched
printf '%s\n' 'role=workload-server root-door=open host=no join=authkey' > "$UNDO_MARKER"
check "bootstrap --undo: old marker names missing provenance" \
  1 "marker predates join-by provenance" undo
check "bootstrap --undo: old marker leaves tailnet untouched" 0 "" undo_untouched
printf '%s\n' 'role=workload-server root-door=open host=no join=authkey join-by=preexisting' > "$UNDO_MARKER"
check "bootstrap --undo: pre-existing join refuses by name" 1 "join-by=preexisting" undo
check "bootstrap --undo: pre-existing join leaves tailnet untouched" 0 "" undo_untouched
printf '%s\n' 'role=runner-server root-door=open host=no join=authkey join-by=rig' > "$UNDO_MARKER"
printf '%s\n' '{}' > "$UNDO_RUNNER/.runner"
check "bootstrap --undo: installed runner points at its removal verb" \
  1 "rig runner remove" undo
check "bootstrap --undo: installed runner leaves tailnet untouched" 0 "" undo_untouched
rm -f "$UNDO_RUNNER/.runner"
check "bootstrap --undo: failed logout is loud" \
  1 "role marker kept" env TAILSCALE_LOGOUT_FAIL=1 PATH="$UNDO_BIN:$PATH" \
    UNDO_CALLS="$UNDO_CALLS" RIG_ROLE_MARKER="$UNDO_MARKER" \
    RIG_RUNNER_DIR="$UNDO_RUNNER" "$ROOT/bin/rig" bootstrap --undo
check "bootstrap --undo: failed logout preserves the marker" 0 "" test -e "$UNDO_MARKER"
: > "$UNDO_CALLS"
check "bootstrap --undo: proven rig join succeeds" 0 "tailnet join removed" undo
check "bootstrap --undo: successful logout was called" 0 "logout" cat "$UNDO_CALLS"
check "bootstrap --undo: success removes the marker" 1 "" test -e "$UNDO_MARKER"
check "bootstrap --undo: second run refuses cleanly" 1 "no /etc/rig/role marker" undo
rm -rf "$UNDO_FIX"
# ...and that it is written in the CURRENT vocabulary (#77). New markers say
# root-door=; the retired class= spelling is something rig READS forever and
# WRITES never, so a marker line that reintroduces it must not ship green.
check "bootstrap: the marker is written as root-door=, not class=" 0 "" \
  grep -qF "printf 'role=%s root-door=%s host=%s join=%s" "$ROOT/commands/bootstrap.sh"
# shellcheck disable=SC2016
check "bootstrap: no shipped script WRITES the retired class= spelling" 0 "" \
  sh -c '! grep -n "printf .*class=" "$1"/commands/*.sh' _ "$ROOT"
# --- host=yes box install (issues #12, #25) --------------------------------
# A host=yes box finishes the job: bootstrap installs the box CLI globally and
# lets box's own setup-host build the Incus stack. The install itself runs as
# root, over the network, against a real host — none of which this harness can
# fabricate — so, exactly like the tag refusals and the runner repo guard, prove
# the shipped script by grepping its load-bearing pieces.
# The step is guarded on host=yes: the exact guard line (no `&&`, unlike the
# /dev/kvm advisory) belongs to the box block alone. The `\$HOST` is a literal
# we grep for in the script — single quotes are the point, as in the db checks.
# shellcheck disable=SC2016
check "bootstrap: box install is guarded on host=yes" 0 "" \
  grep -qxE 'if \[ "\$HOST" = "yes" \]; then' "$ROOT/commands/bootstrap.sh"
# It runs box's OWN global installer with BOX_YES=1 (non-interactive AND keeps
# setup-host, so box builds Incus rather than only dropping the CLI on PATH).
# shellcheck disable=SC2016
check "bootstrap: box install runs box's installer non-interactively" 0 "" \
  grep -q 'BOX_YES=1 BOX_REF="$BOX_REF" bash' "$ROOT/commands/bootstrap.sh"
# The default is a released semver pin carried in rig's tree, never a moving
# branch. BOX_REF remains an override so explicit main and release-branch refs
# still work for development and pre-release drills.
box_release="$(sed -n 's/^[[:space:]]*BOX_RELEASE=//p' "$ROOT/commands/bootstrap.sh")"
check "bootstrap: box default is a released semver pin, not a moving ref" 0 "" \
  grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$box_release"
# shellcheck disable=SC2016
check "bootstrap: BOX_REF overrides the released default" 0 "" \
  grep -qF 'BOX_REF="${BOX_REF:-$BOX_RELEASE}"' "$ROOT/commands/bootstrap.sh"
# Fetching the installer at BOX_REF is only the first pin: box's installer
# independently resolves what it installs, so the ref must cross the pipe too.
# shellcheck disable=SC2016
check "bootstrap: box install passes BOX_REF through the installer pipe" 0 "" \
  grep -qF 'BOX_YES=1 BOX_REF="$BOX_REF" bash' "$ROOT/commands/bootstrap.sh"
# The same pinned command is operators' recovery path on every skip/failure.
# shellcheck disable=SC2016
check "bootstrap: manual box install carries the pinned ref" 0 "" \
  grep -qF 'BOX_YES=1 BOX_REF=${BOX_REF} bash' "$ROOT/commands/bootstrap.sh"
check "bootstrap: box repository remains pinnable" 0 "" \
  grep -qF 'BOX_REPO:-heavy-duty/box' "$ROOT/commands/bootstrap.sh"
# Opt-out for rehearsals / offline / hand-managed hosts.
check "bootstrap: box install honors RIG_SKIP_BOX_INSTALL opt-out" 0 "" \
  grep -q "RIG_SKIP_BOX_INSTALL" "$ROOT/commands/bootstrap.sh"
# The DESIGN LAW rig users apply also enforces: rig NEVER apt-installs Incus —
# box's setup-host is the single owner of the daemon and its group. A grep that
# finds nothing (exit 1) is the pass; a stray `apt-get install ... incus` would
# make it exit 0 and fail the check, so the law cannot silently erode.
check "bootstrap: rig never apt-installs incus (box owns the daemon)" 1 "" \
  grep -nE 'apt-get install.* incus' "$ROOT/commands/bootstrap.sh"
# Ordering is the safety property: box must be installed only AFTER the role
# marker is written, so a box that failed to become what it claims (tag refused,
# join backed out — all of which die above) never installs box on a half-built
# host. Compare line numbers, same idiom as the visudo/sshd -t ordering asserts.
# Defaults fail closed (marker missing -> huge, box missing -> 0 -> fails).
# $MARKER_TMP is a literal we grep for in the script — single quotes intended.
# shellcheck disable=SC2016
box_marker_at="$(grep -n 'install -m 0644 "$MARKER_TMP"' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
box_install_at="$(grep -n 'BOX_YES=1 BOX_REF="$BOX_REF" bash' "$ROOT/commands/bootstrap.sh" | tail -n1 | cut -d: -f1)"
check "bootstrap: box install runs after the role marker write" \
  0 "" test "${box_marker_at:-999999}" -lt "${box_install_at:-0}"
# On the skip/failure paths, keep pointing operators at the manual command so a
# host whose box did not install is never left without the next move.
check "bootstrap: box skip/failure keeps a pointer to the manual install" 0 "" \
  grep -q "prepare Incus" "$ROOT/commands/bootstrap.sh"
# "Don't trust exit codes" (#12): box's installer can exit 0 having done less
# than it claims (its setup-host has a path that exits 0 after only adding a
# group, asking for a re-login). After a claimed success bootstrap must prove
# the one artifact it asked for — box on PATH — and a hollow success WARNS,
# never dies: box is the host extra. Exercising it needs root + the network,
# so grep the shipped script (repo precedent: the tag-refusal greps). Match
# the CALL, not the word — the rationale comment says `command -v box` too.
check "bootstrap: a box-install success is verified, not trusted" 0 "" \
  grep -qE '^[[:space:]]*if command -v box' "$ROOT/commands/bootstrap.sh"
check "bootstrap: a hollow box-install success warns, never dies" 0 "" \
  grep -q "reported success but no 'box' is on PATH" "$ROOT/commands/bootstrap.sh"
# Ordering: the effective check must sit AFTER the installer run it verifies.
# Line-number compare, defaults fail closed (same idiom as the marker/install
# ordering assert above; box_install_at is computed there).
box_check_at="$(grep -nE '^[[:space:]]*if command -v box' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
check "bootstrap: the effective check follows the installer run" \
  0 "" test "${box_install_at:-999999}" -lt "${box_check_at:-0}"
# rig's delegation law caps the check's depth: rig never interrogates Incus —
# the host verdict is box's own verb, and the "host set up" CLAIM is gated on
# it. Two asserts: the gate exists as a call (not just prose naming the verb),
# and the claim line sits inside/after it (line order, fail-closed defaults —
# a claim that outruns its proof is exactly the overclaim this closes).
check "bootstrap: the host-set-up claim is gated on box doctor" 0 "" \
  grep -qE '^[[:space:]]*if box doctor' "$ROOT/commands/bootstrap.sh"
doctor_at="$(grep -nE '^[[:space:]]*if box doctor' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
claim_at="$(grep -n 'box installed and host set up' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
check "bootstrap: the claim follows the doctor gate" \
  0 "" test "${doctor_at:-999999}" -lt "${claim_at:-0}"
check "bootstrap: a failed doctor warns without claiming the host" 0 "" \
  grep -q "the CLI landed, the host stack is unproven" "$ROOT/commands/bootstrap.sh"
# --- the users phase (#51): --users is required, --no-users is the opt-out ----
# Bootstrap takes the users file and applies it as its LAST phase, so one
# command leaves a box with its people on it. Everything about the FLAG is
# provable here — the whole surface sits before the root check, deliberately,
# because a users file with a typo must not be discovered after apt, a hostname
# change and a spent pre-auth key.
BOOT_USERS="$(mktemp -d)"
cat > "$BOOT_USERS/ok" <<'USERS'
dan      admin      ssh-ed25519 AAAAC3fixture dan@laptop
maria    rig        ssh-ed25519 AAAAC3fixture maria@mac
USERS
printf '%s\n' 'dan admin,box ssh-ed25519 AAAAC3fixture dan@laptop' > "$BOOT_USERS/box"
printf '%s\n' 'maria ops ssh-ed25519 AAAA maria@mac'               > "$BOOT_USERS/bad"
# The REQUIREMENT, and the message that carries it: omitting both flags must
# name BOTH ways out, because an operator who forgot the file and one who meant
# to skip it type the identical command — the error is the only place rig can
# tell them apart.
check "bootstrap: omitting --users and --no-users exits 2" 2 "one of --users <path> or --no-users is required" \
  "$ROOT/commands/bootstrap.sh" workload-server
check "bootstrap: the requirement names --no-users as the way out" 2 "--no-users to leave it root-only" \
  "$ROOT/commands/bootstrap.sh" dev-server --hostname b
check "bootstrap: the requirement holds on root-door=open too" 2 "one of --users" \
  "$ROOT/commands/bootstrap.sh" control-plane-server --hostname cp
check "bootstrap: --users needs a value" 2 "needs a value" \
  "$ROOT/commands/bootstrap.sh" workload-server --users
# MUTUAL EXCLUSION, both orders: rig refuses to pick a winner rather than let a
# precedence rule decide who may enter the box. Both orders, because a
# "last flag wins" implementation would pass one of them silently.
check "bootstrap: --users with --no-users exits 2" 2 "contradictory" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/ok" --no-users
check "bootstrap: --no-users with --users exits 2 (either order)" 2 "contradictory" \
  "$ROOT/commands/bootstrap.sh" workload-server --no-users --users "$BOOT_USERS/ok"
# Pre-flight: an unreadable or invalid file dies at the top of the run, exit 2,
# before the root check — the same contract every other flag here has.
check "bootstrap: an unreadable users file exits 2" 2 "cannot read users file" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/nope"
check "bootstrap: an invalid users file exits 2 with the parser's errors" 2 "invalid users file" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/bad"
check "bootstrap: the invalid-file refusal carries the parser's own line error" 2 "valid roles: admin rig box" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/bad"
# '-' is apply's stdin convenience and cannot survive the trip through
# bootstrap: stdin here is the pre-auth key prompt's. Refused, with the split
# ('--no-users' then apply by hand) named.
check "bootstrap: --users - is refused, naming the pre-auth key prompt" 2 "pre-auth key prompt" \
  "$ROOT/commands/bootstrap.sh" workload-server --users -
# A file that parses to ZERO users (#57). Not a parse error — the parser is
# right to accept empty, comments-only and whitespace-only files — but it walks
# straight through #51's requirement: `--users ./empty` and `--no-users`
# converge the identical root-only box, and only one of them says so. All three
# shapes are tested separately because they take different paths through the
# parser's skip rules, and an implementation that checked, say, file size alone
# would pass one and fail the others.
: > "$BOOT_USERS/empty"
cat > "$BOOT_USERS/comments" <<'USERS'
# the operators for this box
#dan     admin      ssh-ed25519 AAAAC3fixture dan@laptop
USERS
printf '   \n\t\n\n' > "$BOOT_USERS/blank"
check "bootstrap: an empty users file exits 2" 2 "names no users" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/empty"
check "bootstrap: a comments-only users file exits 2" 2 "names no users" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/comments"
check "bootstrap: a whitespace-only users file exits 2" 2 "names no users" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/blank"
# The refusal must name --no-users, for the same reason the missing-flag one
# does: the root-only box IS reachable, it just has to be said out loud. An
# error that only reported "no users" would leave the operator who genuinely
# wants root-only with no named way to ask for it.
check "bootstrap: the zero-user refusal names --no-users as the way to say it" 2 "pass --no-users to leave this box root-only" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/empty"
# It must NOT over-refuse: a file that names even one operator passes pre-flight
# untouched. Reaching the root check (exit 1) is the proof — same idiom as the
# incus precondition's negative cases below.
if [ "$(id -u)" -ne 0 ]; then
  check "bootstrap: a users file naming operators still passes pre-flight" 1 "must run as root" \
    env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/ok"
fi
# Scope guard (#57): the refusal is BOOTSTRAP's contract, not the parser's and
# not apply's. A standalone `rig users apply` against an emptied file is a real
# de-provisioning operation and must stay possible — greps that find nothing
# (exit 1) are the pass, the repo's negative-law idiom.
check "users apply: an empty file is still a legal de-provisioning input" 1 "" \
  grep -nE 'names no users' "$ROOT/commands/users-apply.sh"
check "users-config: zero users stays bootstrap policy, not a parser error" 1 "" \
  grep -nE 'names no users' "$ROOT/commands/lib/users-config.sh"
# The host=yes box-role precondition, surfaced EARLY — but only where the
# outcome is already proven: RIG_SKIP_BOX_INSTALL=1 means this run will not
# install box, so a missing incus group can no longer be rescued by the install
# further down. The group's presence is a property of whatever machine runs
# this harness, so it is driven with a shim `getent` instead — both directions,
# on any machine (repo precedent: the install.sh getent shim below).
#
# The box CLI's presence is the SECOND half of the precondition (#49 merged a
# matching die into apply), and it is a property of the runner in exactly the
# same way — this machine happens to have box on PATH, a CI runner may not. So
# it is shimmed in both directions too, and `box` is deliberately NOT inherited
# from the real PATH in these runs: a test that passes only where box happens
# to be installed proves nothing about the machine where it isn't.
INCUS_SHIM_NO="$BOOT_USERS/shim-no"; INCUS_SHIM_YES="$BOOT_USERS/shim-yes"
BOXLESS_SHIM="$BOOT_USERS/shim-nobox"
mkdir -p "$INCUS_SHIM_NO" "$INCUS_SHIM_YES" "$BOXLESS_SHIM"
# Answer only the `group incus` question; everything else falls through to the
# real getent, so the shim cannot quietly change some other lookup's answer.
cat > "$INCUS_SHIM_NO/getent" <<'SHIM'
#!/bin/sh
if [ "$1" = group ] && [ "$2" = incus ]; then exit 2; fi
exec /usr/bin/getent "$@"
SHIM
cat > "$INCUS_SHIM_YES/getent" <<'SHIM'
#!/bin/sh
if [ "$1" = group ] && [ "$2" = incus ]; then echo "incus:x:900:"; exit 0; fi
exec /usr/bin/getent "$@"
SHIM
# Group present, box absent — the shape #49's die now owns, and the one the
# old group-only precondition let through to fail a hundred lines later.
cat > "$BOXLESS_SHIM/getent" <<'SHIM'
#!/bin/sh
if [ "$1" = group ] && [ "$2" = incus ]; then echo "incus:x:900:"; exit 0; fi
exec /usr/bin/getent "$@"
SHIM
# A `box` that exists, for the satisfied case — so INCUS_SHIM_YES proves the
# precondition passes on its own terms rather than on the runner's luck.
printf '#!/bin/sh\nexit 0\n' > "$INCUS_SHIM_YES/box"
chmod +x "$INCUS_SHIM_NO/getent" "$INCUS_SHIM_YES/getent" \
         "$BOXLESS_SHIM/getent" "$INCUS_SHIM_YES/box"
check "bootstrap: host=yes + box role + no incus + skipped box install exits 2" 2 "group incus is absent" \
  env RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_NO:$PATH" \
      "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
check "bootstrap: that refusal points at box setup-host, not at rig" 2 "rig never installs Incus" \
  env RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_NO:$PATH" \
      "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
# The group can be there while the CLI is not — #49's die owns that shape, and
# under the skip it is just as final and just as knowable now. PATH is built
# WITHOUT the real one so the absence is the test's, not the machine's.
check "bootstrap: host=yes + box role + incus group + no box CLI + skip exits 2" 2 "box CLI is not on PATH" \
  env RIG_SKIP_BOX_INSTALL=1 PATH="$BOXLESS_SHIM:/usr/bin:/bin" \
      "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
check "bootstrap: that refusal names the tier, not just the socket" 2 "the restricted tier is 'box grant'" \
  env RIG_SKIP_BOX_INSTALL=1 PATH="$BOXLESS_SHIM:/usr/bin:/bin" \
      "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
if [ "$(id -u)" -ne 0 ]; then
  # It must NOT fire in the three shapes that are not doomed. A users file with
  # no box-role user converges fine on a host that never saw Incus (refusing it
  # would be rig inventing a prerequisite apply does not have); an incus group
  # that exists satisfies it outright; and WITHOUT RIG_SKIP_BOX_INSTALL the
  # missing group is the box install's to create further down — refusing there
  # would reject the exact one-command bring-up this flag is for. Reaching the
  # root check (exit 1) is the proof each passed the precondition.
  check "bootstrap: no box-role user means no incus precondition" 1 "must run as root" \
    env TS_AUTHKEY=x RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_NO:$PATH" \
        "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/ok"
  check "bootstrap: an existing incus group satisfies the precondition" 1 "must run as root" \
    env TS_AUTHKEY=x RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_YES:$PATH" \
        "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
  check "bootstrap: without the skip, the box install is left to create the group" 1 "must run as root" \
    env TS_AUTHKEY=x PATH="$INCUS_SHIM_NO:$PATH" \
        "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
  # host=no is the other side of apply's host= rule — the box role is skipped
  # with a warning there, never refused, so bootstrap must not refuse it either.
  check "bootstrap: host=no never gets the incus precondition" 1 "must run as root" \
    env TS_AUTHKEY=x RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_NO:$PATH" \
        "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/box"
fi
# rig does NOT resolve the open "should rig install box" question here: the
# precondition refuses, it never calls setup-host itself. A grep that finds
# nothing (exit 1) is the pass — same shape as the never-apt-install-incus law.
check "bootstrap: the users phase never runs box setup-host itself" 1 "" \
  grep -nE '^[[:space:]]*box setup-host' "$ROOT/commands/bootstrap.sh"
# ORDERING is a correctness property, not taste: apply READS /etc/rig/role
# (root-door= picks its root-SSH note, host= decides what a missing incus group
# means), and on host=yes it needs the group box's installer built. So the
# users phase must sit after BOTH the marker write and the box install. Line
# numbers, same idiom as the marker/box-install ordering asserts above;
# defaults fail closed. The apply call is grepped as a literal — single quotes
# intended, $HERE/$USERS_FILE are the script's own.
# shellcheck disable=SC2016
users_apply_at="$(grep -n '"$HERE/users-apply.sh" --file "$USERS_FILE"' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
check "bootstrap: the users phase invokes users apply" 0 "" \
  test -n "$users_apply_at"
check "bootstrap: the users phase runs after the role marker write" \
  0 "" test "${box_marker_at:-999999}" -lt "${users_apply_at:-0}"
check "bootstrap: the users phase runs after the box install" \
  0 "" test "${box_install_at:-999999}" -lt "${users_apply_at:-0}"
# The users file is passed per invocation and NEVER persisted (README: "rig
# never persists it"). Taking it as a bootstrap flag must not quietly turn it
# into box state, so nothing may copy it anywhere. A grep that finds nothing
# (exit 1) is the pass — same shape as the never-apt-install-incus law.
check "bootstrap: the users file is never copied onto the box" 1 "" \
  grep -nE '^[[:space:]]*(cp|install|mv|tee|cat)[[:space:]].*USERS_FILE' "$ROOT/commands/bootstrap.sh"
# Usage must carry both flags: an operator hitting the new requirement reads
# --help next, and finding only --users there would leave the opt-out a secret.
check "bootstrap: usage documents --users"    0 "--users"    "$ROOT/commands/bootstrap.sh" --help
check "bootstrap: usage documents --no-users" 0 "--no-users" "$ROOT/commands/bootstrap.sh" --help
check "rig usage documents the bootstrap users flags" 0 "(--users <path> | --no-users)" \
  "$ROOT/bin/rig" --help
# The TENANT family takes neither flag. Dispatch happens before this parser
# runs, so --users lands in the tenant script's own unknown-flag refusal — the
# decision (a box-minted guest has no SSH door of its own; entry is `box shell`,
# gated by the HOST's incus grants) is documented in usage and the README.
check "bootstrap: --users does not reach the tenant roles" 2 "unknown flag" \
  "$ROOT/commands/bootstrap.sh" claude-box --users "$BOOT_USERS/ok"
check "bootstrap: usage explains why tenants take no --users" 0 "box-minted GUEST" \
  "$ROOT/commands/bootstrap.sh" --help
# --- README: install channels (#89) ------------------------------------------
# The README on main documents main's CLI, so its FIRST full install command
# must opt into that tree instead of silently selecting an older release.
readme_first_full_install="$(grep -m1 -F 'curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/main/install.sh' "$ROOT/README.md")"
check "README: the main-branch quick start installs the documented tree" 0 "" \
  test "$readme_first_full_install" = \
    'curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/main/install.sh | RIG_REF=main bash'
check "README: no stale pre-0.1.0 release notice" 1 "" \
  grep -qF 'Until rig cuts 0.1.0' "$ROOT/README.md"
check "README: still documents the latest-release channel" 0 "" \
  grep -qF 'curl -fsSL .../install.sh | bash                   # the latest release' "$ROOT/README.md"
# $RIG_HOME is the literal path spelling the README must show operators.
# shellcheck disable=SC2016
check "README: names the stable channel's installed documentation" 0 "" \
  grep -qF '$RIG_HOME/current/README.md' "$ROOT/README.md"
check "README: still documents a pinned semver-tag channel" 0 "" \
  grep -Eq '^curl -fsSL \.\.\./install\.sh \| RIG_REF=[0-9]+\.[0-9]+\.[0-9]+ bash +# pinned to a release$' "$ROOT/README.md"

# --- README: the box rename (#12) --------------------------------------------
# The philosophy line must point at heavy-duty/box — the old claudebox slug
# only works through a GitHub redirect that one squatted rename away from
# breaking (box's own installer was already bitten by the rename once). A
# negative grep (exit 1 = pass) keeps the stale slug from creeping back.
check "README: no stale heavy-duty/claudebox links" 1 "" \
  grep -n "heavy-duty/claudebox" "$ROOT/README.md"
check "README: points at heavy-duty/box" 0 "" \
  grep -q "github.com/heavy-duty/box" "$ROOT/README.md"

# The users-apply section is the operator's reference for what the box role
# does, and #58 inverted its central claim: the trait decides in BOTH
# directions now, and the group's presence never overrides it. A reference
# that still says "when the incus group is absent, the host= trait decides"
# asserts the very bypass that was the bug. Pinned in both directions — the
# current sentence present, the superseded one gone — so the prose cannot
# drift back to describing a semantics the code no longer has.
check "README: the trait gates the box role regardless of the group" 0 "" \
  grep -q "the \`incus\` group never overrides it" "$ROOT/README.md"
check "README: documents the mismatch strip on host=no" 0 "" \
  grep -q "half-grant is the same defect as a fresh one" "$ROOT/README.md"
check "README: no stale 'group absent decides' semantics" 1 "" \
  grep -n "when the \`incus\` group is absent, the \`host=\` trait decides" "$ROOT/README.md"
if [ "$(id -u)" -ne 0 ]; then
  # Every machine-role invocation now states its users answer — the flag is
  # required (#51), so reaching the root check at all proves it was accepted.
  # --no-users here keeps these asserts about the ROOT CHECK; the --users path
  # gets its own root-check assert below, against a valid fixture.
  check "bootstrap: refuses non-root"      1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workload-server --no-users
  check "bootstrap: --users file reaches the root check" 1 "must run as root" \
    env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/ok"
  check "bootstrap: runner role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" runner-server --no-users
  # staging-box dispatches to the tenant mechanism; reaching ITS root check
  # through bootstrap.sh proves the dispatch and the tenant arg pass in one go.
  # RIG_ROLE_MARKER points at an absent fixture: the tenant marker guard runs
  # before the root check, and the machine running this harness may well have
  # a real /etc/rig/role of its own.
  check "bootstrap: staging-box dispatches to the tenant mechanism, refuses non-root" 1 "must run as root" \
    env RIG_ROLE_MARKER=/nonexistent/rig-role "$ROOT/commands/bootstrap.sh" staging-box
  check "bootstrap: dev role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" dev-server --no-users
  check "bootstrap: workstation parses, refuses non-root" 1 "must run as root" env -u TS_AUTHKEY "$ROOT/commands/bootstrap.sh" workstation --no-users
  check "bootstrap: custom parses, refuses non-root" 1 "must run as root" \
    env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" custom --hostname b --root-door open --host no --join authkey --no-users
else
  echo "skip: bootstrap non-root refusals (running as root)"
fi

# --- box tenant roles (#31/#76/#110): <role>-box from the registry + staging-box ---
# What a box-minted guest becomes — ONE mechanism (bootstrap-tenant.sh),
# parameterized per DEFINITION fetched from the template registry
# (heavy-duty/rig-templates; lib/templates.sh resolves RIG_TEMPLATES_DIR >
# RIG_TEMPLATES_REF > the in-tree pin), dispatched from bootstrap.sh on the
# '-box' FAMILY SUFFIX so `rig bootstrap <role>` stays the single entrypoint
# and a template added to the registry is mintable with zero code changes
# here. The real converge needs root, a tenant user, and the network — the
# container rehearsal's job — so the harness proves what it can non-root and
# OFFLINE: the whole refusal surface, the resolution precedence, the parser
# and the renderer, against fixture definitions via RIG_TEMPLATES_DIR.

# The fixture registry: one valid scratch definition, plus broken ones the
# parser must refuse BY NAME. Synthetic on purpose — the real definitions
# live in heavy-duty/rig-templates, and this suite must hold whatever those
# say (offline is the point: no fetch, no network, no coupling).
TPL_FIX="$(mktemp -d)"
mkdir -p "$TPL_FIX/scratch-box"
cat > "$TPL_FIX/scratch-box/template.env" <<'TPLEOF'
# comments and blank lines are the only non-KEY="value" grammar

USER="scratch"
CONTEXT_PATH=".scratch/AGENTS.md"
CLI_NAME="scratch"
CLI_SRC="~/.local/bin/scratch"
PATH_LINE="export PATH="$HOME/.local/bin:$PATH""
NEEDS_NODE="no"
APT_EXTRAS="zsh"
TPLEOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$TPL_FIX/scratch-box/install.sh"
printf -- '- **Creds-free by default.** The scratch vendor paragraph.\n' > "$TPL_FIX/scratch-box/creds.md"
mkdir -p "$TPL_FIX/badkey-box"
printf 'USER="x"\nCOLOR="red"\n' > "$TPL_FIX/badkey-box/template.env"
mkdir -p "$TPL_FIX/missing-box"
printf 'USER="x"\nCONTEXT_PATH=".x/A.md"\nPATH_LINE="p"\n' > "$TPL_FIX/missing-box/template.env"
mkdir -p "$TPL_FIX/garbled-box"
printf 'USER=unquoted\n' > "$TPL_FIX/garbled-box/template.env"
mkdir -p "$TPL_FIX/badnode-box"
printf 'USER="x"\nCONTEXT_PATH=".x/A.md"\nCLI_NAME="x"\nPATH_LINE="p"\nNEEDS_NODE="maybe"\n' > "$TPL_FIX/badnode-box/template.env"
mkdir -p "$TPL_FIX/badapt-box"
printf 'USER="x"\nCONTEXT_PATH=".x/A.md"\nCLI_NAME="x"\nPATH_LINE="p"\nAPT_EXTRAS="zsh -o"\n' > "$TPL_FIX/badapt-box/template.env"
mkdir -p "$TPL_FIX/scratch-server"
printf 'ROOT_DOOR="closed"\nHOST="no"\nJOIN="login"\n' > "$TPL_FIX/scratch-server/template.env"
mkdir -p "$TPL_FIX/workstation"
printf 'ROOT_DOOR="closed"\nHOST="yes"\nJOIN="authkey"\n' > "$TPL_FIX/workstation/template.env"
mkdir -p "$TPL_FIX/baddoor-server"
printf 'ROOT_DOOR="ajar"\nHOST="no"\nJOIN="authkey"\n' > "$TPL_FIX/baddoor-server/template.env"
mkdir -p "$TPL_FIX/tenantkeys-server"
cp "$TPL_FIX/scratch-box/template.env" "$TPL_FIX/tenantkeys-server/template.env"
mkdir -p "$TPL_FIX/machinekeys-box"
cp "$TPL_FIX/scratch-server/template.env" "$TPL_FIX/machinekeys-box/template.env"
mkdir -p "$TPL_FIX/creds-server"
cp "$TPL_FIX/scratch-server/template.env" "$TPL_FIX/creds-server/template.env"
printf 'not used\n' > "$TPL_FIX/creds-server/creds.md"
mkdir -p "$TPL_FIX/noshebang-server"
cp "$TPL_FIX/scratch-server/template.env" "$TPL_FIX/noshebang-server/template.env"
printf 'exit 0\n' > "$TPL_FIX/noshebang-server/install.sh"

# THE HARD CUT, tenant half (#76). The pre-rename names are gone and must fail
# as UNKNOWN — asserted per name, because an alias left in for one tenant is the
# shape that survives review. And the #110 cut on top: the mechanism no longer
# KNOWS any agent tenant by name — which '-box' roles exist is the registry's
# fact, so the old names die on the family-suffix rule, not an enumerated list.
for r in claude codex grok staging; do
  check "tenant: the pre-#76 name '$r' is gone (tenant entrypoint)" 2 "unknown tenant role" \
    "$ROOT/commands/bootstrap-tenant.sh" "$r"
  check "tenant: the pre-#76 name '$r' is gone (bootstrap dispatch)" 2 "unknown role" \
    "$ROOT/commands/bootstrap.sh" "$r"
done
check "tenant: --help exits 0"          0 "usage:" "$ROOT/commands/bootstrap-tenant.sh" --help
check "tenant: role required, exit 2"   2 "tenant role required" "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: a suffix-less role exits 2" 2 "unknown tenant role" "$ROOT/commands/bootstrap-tenant.sh" potato
check "tenant: unknown flag exits 2"    2 "unknown flag" "$ROOT/commands/bootstrap-tenant.sh" claude-box --nope
check "tenant: --user needs value"      2 "needs a value" "$ROOT/commands/bootstrap-tenant.sh" claude-box --user
check "tenant: bad --user charset exits 2" 2 "invalid user" "$ROOT/commands/bootstrap-tenant.sh" claude-box --user 'fo|o'
# The suffix rule admits ANY '-box' name, so the charset gate must catch a
# crafted one BEFORE it is used as a path component (the valid_version
# discipline): uppercase, dots, a leading '-' all die at the name, never in a
# registry lookup.
check "tenant: a crafted role name dies at the charset gate" 2 "invalid tenant role name" \
  "$ROOT/commands/bootstrap-tenant.sh" 'UPPER-box'
check "tenant: dockerd effective-state assert is present" 0 "" \
  grep -qF "docker info" "$ROOT/commands/bootstrap-tenant.sh"
# The #162 contract, both halves: cron installs with the agent toolbelt (the
# duty engine's unprivileged installer can never apt-get it), and PATH is not
# the effective state — the service must be asserted enabled AND active, or a
# masked daemon leaves every tenant crontab silently inert.
check "tenant: cron rides the agent toolbelt install" 0 "" \
  grep -qE '^ *apt-get install .* cron ' "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: crontab toolbelt assert is present" 0 "" \
  grep -qF "command -v crontab" "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: cron.service enabled assert is present" 0 "" \
  grep -qF "systemctl is-enabled cron" "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: cron.service active assert is present" 0 "" \
  grep -qF "systemctl is-active cron" "$ROOT/commands/bootstrap-tenant.sh"

# #164: tenant scratch lives on the disk-backed home filesystem. Lift the
# real convergers and drive them against fixture homes and per-user crontabs:
# production needs root for ownership, while this harness proves the same-user
# case without mutating this box or any real crontab.
TMPDIR_FNS="$(sed -n '/^append_line_once() {/,/^}/p; /^converge_user_crontab_assignment() {/,/^}/p; /^converge_tenant_tmpdir() {/,/^}/p' "$ROOT/commands/bootstrap-tenant.sh")"
# shellcheck disable=SC2016  # expanded by the inner bash
check "tenant TMPDIR: convergers lift out of the real file whole" 0 "" \
  bash -c '[ "$(printf %s "$1" | grep -c "^}$")" -eq 3 ]' _ "$TMPDIR_FNS"
check "tenant TMPDIR: converge is invoked for agent tenants" 0 "" \
  grep -qE '^  converge_tenant_tmpdir$' "$ROOT/commands/bootstrap-tenant.sh"

# shellcheck disable=SC2120  # inner bash consumes its own positional arguments
drive_tmpdir() {
  local d user group before after
  d="$(mktemp -d)"
  user="$(id -un)"; group="$(id -gn)"
  mkdir -p "$d/home" "$d/crontabs"
  printf 'MAILTO=tenant\n*/5 * * * * /tenant-job\nTMPDIR=/tmp/stale\n' > "$d/crontabs/$user"
  printf 'MAILTO=peer\n*/5 * * * * /peer-job\n' > "$d/crontabs/peer"
  printf 'MAILTO=root\n*/5 * * * * /root-job\n' > "$d/crontabs/root"
  cp "$d/crontabs/peer" "$d/peer.before"
  cp "$d/crontabs/root" "$d/root.before"
  before="$(find /tmp -mindepth 1 -maxdepth 1 | wc -l)"
  TENANT_USER="$user" TENANT_GROUP="$group" TENANT_HOME="$d/home" \
    RIG_CRON_DIR="$d/crontabs" bash -c '
      set -euo pipefail
      log() { :; }
      die() { printf "%s\n" "$1" >&2; exit "${2:-1}"; }
      runuser() {
        case "$1" in
          -u) shift 2; [ "$1" != -- ] || shift; "$@" ;;
          -l) shift 2; [ "$1" = -c ]; ( export HOME="$TENANT_HOME"; . "$HOME/.profile"; eval "$2" ) ;;
          *) return 2 ;;
        esac
      }
      df() { printf "Filesystem Type 1024-blocks Used Available Capacity Mounted on\nfixture ext4 1 1 1 1%% %s\n" "$2"; }
      crontab() {
        [ "$1" = -u ] || return 2
        local target="$2"
        shift 2
        case "${1:-}" in
          -l) [ -f "$RIG_CRON_DIR/$target" ] || return 1; command cat "$RIG_CRON_DIR/$target" ;;
          *) command cp "$1" "$RIG_CRON_DIR/$target" ;;
        esac
      }
      '"$TMPDIR_FNS"'
      converge_tenant_tmpdir
      converge_tenant_tmpdir
      profile_tmpdir="$(HOME="$TENANT_HOME" bash -c ". \"$TENANT_HOME/.profile\"; printf %s \"\$TMPDIR\"")"
      zsh_tmpdir="$(HOME="$TENANT_HOME" bash -c ". \"$TENANT_HOME/.zshenv\"; printf %s \"\$TMPDIR\"")"
      cron_tmpdir="$(sed -n "s/^TMPDIR=//p" "$RIG_CRON_DIR/$TENANT_USER")"
      made="$(TMPDIR="$cron_tmpdir" mktemp)"
      cmp -s "$RIG_CRON_DIR/peer" "${RIG_CRON_DIR%/*}/peer.before" && peer_unchanged=yes || peer_unchanged=no
      cmp -s "$RIG_CRON_DIR/root" "${RIG_CRON_DIR%/*}/root.before" && root_unchanged=yes || root_unchanged=no
      printf "expected=%s\nprofile=%s\nzsh=%s\ncron=%s\nmade=%s\nmode=%s\nprofile-lines=%s\nzsh-lines=%s\ncron-lines=%s\ntenant-job-lines=%s\npeer-unchanged=%s\nroot-unchanged=%s\n" \
        "$TENANT_HOME/tmp" "$profile_tmpdir" "$zsh_tmpdir" "$cron_tmpdir" "$made" \
        "$(stat -c "%U:%G %a" "$TENANT_HOME/tmp")" \
        "$(grep -c "^export TMPDIR=" "$TENANT_HOME/.profile")" \
        "$(grep -c "^export TMPDIR=" "$TENANT_HOME/.zshenv")" \
        "$(grep -c "^TMPDIR=" "$RIG_CRON_DIR/$TENANT_USER")" \
        "$(grep -c "/tenant-job$" "$RIG_CRON_DIR/$TENANT_USER")" \
        "$peer_unchanged" "$root_unchanged"
      rm -f "$made"
    '
  after="$(find /tmp -mindepth 1 -maxdepth 1 | wc -l)"
  printf 'tmp-count=%s:%s\n' "$before" "$after"
  rm -rf "$d"
}
# shellcheck disable=SC2119  # drive_tmpdir itself takes no arguments
TMPDIR_DRIVE="$(drive_tmpdir)"
tmpdir_has() { printf '%s' "$TMPDIR_DRIVE" | grep -qF -e "$1"; }
# shellcheck disable=SC2016  # expanded by the inner bash
check "tenant TMPDIR: bash profile resolves to the exact tenant disk path" 0 "" \
  bash -c 'x=$(printf %s "$1" | sed -n "s/^expected=//p"); p=$(printf %s "$1" | sed -n "s/^profile=//p"); [ "$p" = "$x" ]' _ "$TMPDIR_DRIVE"
# shellcheck disable=SC2016  # expanded by the inner bash
check "tenant TMPDIR: zsh login carrier resolves to the exact tenant disk path" 0 "" \
  bash -c 'x=$(printf %s "$1" | sed -n "s/^expected=//p"); z=$(printf %s "$1" | sed -n "s/^zsh=//p"); [ "$z" = "$x" ]' _ "$TMPDIR_DRIVE"
# shellcheck disable=SC2016  # expanded by the inner bash
check "tenant TMPDIR: cron resolves to the exact tenant disk path" 0 "" \
  bash -c 'x=$(printf %s "$1" | sed -n "s/^expected=//p"); c=$(printf %s "$1" | sed -n "s/^cron=//p"); [ "$c" = "$x" ]' _ "$TMPDIR_DRIVE"
# shellcheck disable=SC2016  # expanded by the inner bash
check "tenant TMPDIR: cron-launched mktemp writes below tenant scratch" 0 "" \
  bash -c 'p=$(printf %s "$1" | sed -n "s/^made=//p"); x=$(printf %s "$1" | sed -n "s/^expected=//p"); case "$p" in "$x"/*) exit 0;; *) exit 1;; esac' _ "$TMPDIR_DRIVE"
check "tenant TMPDIR: directory ownership and private tmp semantics converge" 0 "" \
  tmpdir_has "mode=$(id -un):$(id -gn) 700"
check "tenant TMPDIR: profile export is idempotent" 0 "" tmpdir_has "profile-lines=1"
check "tenant TMPDIR: zsh export is idempotent" 0 "" tmpdir_has "zsh-lines=1"
check "tenant TMPDIR: stale cron assignments are replaced once" 0 "" tmpdir_has "cron-lines=1"
check "tenant TMPDIR: existing tenant cron jobs survive" 0 "" tmpdir_has "tenant-job-lines=1"
check "tenant TMPDIR: peer crontab is untouched" 0 "" tmpdir_has "peer-unchanged=yes"
check "tenant TMPDIR: root crontab is untouched" 0 "" tmpdir_has "root-unchanged=yes"
check "tenant TMPDIR: no machine-wide environment carrier remains" 1 "" \
  grep -E 'RIG_ENVIRONMENT_FILE|/etc/environment|pam_env' "$ROOT/commands/bootstrap-tenant.sh"
# shellcheck disable=SC2016  # expanded by the inner bash
check "tenant TMPDIR: the fixture leaves /tmp usage flat" 0 "" \
  bash -c 'v=$(printf %s "$1" | sed -n "s/^tmp-count=//p"); [ "${v%:*}" = "${v#*:}" ]' _ "$TMPDIR_DRIVE"

drive_tmpdir_failure() {
  local shape="$1" d user group
  d="$(mktemp -d)"
  user="$(id -un)"; group="$(id -gn)"
  mkdir -p "$d/home" "$d/crontabs"
  case "$shape" in
    file) : > "$d/home/tmp" ;;
    symlink) ln -s "$d/elsewhere" "$d/home/tmp" ;;
    tmpfs) mkdir "$d/home/tmp" ;;
  esac
  TENANT_USER="$user" TENANT_GROUP="$group" TENANT_HOME="$d/home" \
    RIG_CRON_DIR="$d/crontabs" RIG_TEST_FSTYPE="$shape" bash -c '
      set -euo pipefail
      log() { :; }
      die() { printf "%s\n" "$1" >&2; exit "${2:-1}"; }
      runuser() { [ "$1" = -u ]; shift 2; [ "$1" != -- ] || shift; "$@"; }
      crontab() { return 0; }
      df() { printf "Filesystem Type 1024-blocks Used Available Capacity Mounted on\nfixture %s 1 1 1 1%% %s\n" "${RIG_TEST_FSTYPE/tmpfs/tmpfs}" "$2"; }
      '"$TMPDIR_FNS"'
      converge_tenant_tmpdir
    ' 2>&1
  local rc=$?
  rm -rf "$d"
  return "$rc"
}
check "tenant TMPDIR: a pre-existing file fails deliberately" 1 "not a directory" \
  drive_tmpdir_failure file
check "tenant TMPDIR: a pre-existing symlink fails deliberately" 1 "not a directory" \
  drive_tmpdir_failure symlink
check "tenant TMPDIR: a tmpfs scratch path is refused" 1 "not disk-backed (tmpfs)" \
  drive_tmpdir_failure tmpfs

# The converge is exercised, not argued about (the drop_incus precedent):
# converge_cron is lifted out of the real file verbatim — column-0
# 'converge_cron() {' through column-0 '}' — and driven against a stub
# systemctl whose effective state lives in files. The extraction is asserted
# first: if that shape ever changes the lift comes back empty and every case
# below fails loudly rather than passing vacuously.
CRON_FN="$(sed -n '/^converge_cron() {/,/^}/p' "$ROOT/commands/bootstrap-tenant.sh")"
# shellcheck disable=SC2016  # $1 is the inner bash -c's positional, deliberately
check "tenant: converge_cron lifts out of the real file whole" 0 "" \
  bash -c '[ -n "$1" ] && printf %s "$1" | grep -q "^}$"' _ "$CRON_FN"
# ...and the function must actually be CALLED — a lifted-and-driven function
# nobody invokes proves nothing about bootstrap.
check "tenant: converge_cron is invoked" 0 "" \
  grep -qE '^ *converge_cron$' "$ROOT/commands/bootstrap-tenant.sh"

CRON_BASH="$(command -v bash)"
# drive_cron <noop|converge|masked|deadstart> — the real converge_cron against
# a stub systemctl. Effective state is files: 'enabled'/'active' existing means
# the probe passes. 'noop': both preexist — the idempotent re-run. 'converge':
# neither, and enable/start take effect. 'masked': neither, and enable/start do
# NOTHING — the unrecoverably-inert daemon #162 is about. 'deadstart': enabled,
# but start never takes. The stub logs its calls to a file: the real call sites
# are '>/dev/null 2>&1', so a stub that spoke on either stream would be
# silenced and the call assertions below would pass vacuously.
drive_cron() {
  local mode="$1" d
  d="$(mktemp -d)"
  mkdir -p "$d/bin"
  case "$mode" in noop) : > "$d/enabled"; : > "$d/active" ;; deadstart) : > "$d/enabled" ;; esac
  # The stub restores a real PATH for itself: the caller's PATH is REPLACED by
  # the stub dir (that is what keeps a host systemctl out of reach), which
  # would otherwise leave the stub unable to find 'echo' as an executable.
  cat > "$d/bin/systemctl" <<EOF
#!/bin/sh
PATH=/usr/bin:/bin
echo "systemctl \$*" >> "$d/calls"
case "\$1" in
  is-enabled) [ -e "$d/enabled" ] ;;
  is-active)  [ -e "$d/active" ] ;;
  enable) case "$mode" in noop|converge) : > "$d/enabled" ;; esac ;;
  start)  case "$mode" in noop|converge) : > "$d/active" ;; esac ;;
esac
EOF
  chmod +x "$d/bin/systemctl"
  # The driving shell mirrors the real script: same set flags, same log/die.
  # shellcheck disable=SC2016  # $*/$1/$2 resolve inside the driving shell
  PATH="$d/bin" "$CRON_BASH" -c '
    set -euo pipefail
    log() { printf "rig-bootstrap: %s\n" "$*"; }
    die() { printf "rig-bootstrap: ERROR: %s\n" "$1" >&2; exit "${2:-1}"; }
    '"$CRON_FN"'
    converge_cron' 2>&1
  echo "RC=$?"
  cat "$d/calls" 2>/dev/null
  rm -rf "$d"
}
CRON_NOOP="$(drive_cron noop)"
CRON_CONV="$(drive_cron converge)"
CRON_MASK="$(drive_cron masked)"
CRON_DEAD="$(drive_cron deadstart)"
cron_has() { printf '%s' "$1" | grep -qF -e "$2"; }   # cron_has <captured> <substr>

# The idempotent re-run: both probes already pass, NOTHING is converged and
# nothing dies — a second bootstrap must not touch the unit.
check "converge_cron: already enabled+active exits 0" 0 "" cron_has "$CRON_NOOP" "RC=0"
check "converge_cron: the no-op never calls unmask" 1 "" cron_has "$CRON_NOOP" "systemctl unmask"
check "converge_cron: the no-op never calls enable" 1 "" cron_has "$CRON_NOOP" "systemctl enable"
check "converge_cron: the no-op never calls start" 1 "" cron_has "$CRON_NOOP" "systemctl start"
# The converge path: a disabled, stopped unit is unmasked, enabled, started —
# and the asserts then pass on systemd's own answer, exit 0.
check "converge_cron: disabled+inactive converges, exits 0" 0 "" cron_has "$CRON_CONV" "RC=0"
check "converge_cron: the converge unmasks" 0 "" cron_has "$CRON_CONV" "systemctl unmask cron"
check "converge_cron: the converge enables" 0 "" cron_has "$CRON_CONV" "systemctl enable cron"
check "converge_cron: the converge starts" 0 "" cron_has "$CRON_CONV" "systemctl start cron"
# The log states the probe fact, never a success it did not verify.
check "converge_cron: the log states the probe fact" 0 "" \
  cron_has "$CRON_CONV" "cron.service not enabled — converging"
# THE #162 FAILURE: a converge that does not take effect DIES, nonzero, naming
# cron — never a silent success wrapping an inert timer.
check "converge_cron: an unrecoverable unit dies nonzero" 0 "" cron_has "$CRON_MASK" "RC=1"
check "converge_cron: the death names the enabled assert" 0 "" \
  cron_has "$CRON_MASK" "cron.service is not enabled after converge"
check "converge_cron: the death cites #162" 0 "" cron_has "$CRON_MASK" "#162"
check "converge_cron: the dying path tried to converge first" 0 "" \
  cron_has "$CRON_MASK" "systemctl unmask cron"
# Enabled but the start never takes: the ACTIVE assert dies — enabled alone
# is not an armed timer.
check "converge_cron: enabled-but-dead start dies nonzero" 0 "" cron_has "$CRON_DEAD" "RC=1"
check "converge_cron: that death names the active assert" 0 "" \
  cron_has "$CRON_DEAD" "cron.service is not active after converge"
# The machine-role traits die with the tenant story, never "unknown flag" — an
# operator coming from the machine families needs the boundary, not a shrug.
check "tenant: trait flags die with the tenant story" 2 "have no traits" \
  "$ROOT/commands/bootstrap-tenant.sh" claude-box --root-door closed
check "tenant: --hostname dies the same way" 2 "have no traits" \
  "$ROOT/commands/bootstrap-tenant.sh" staging-box --hostname my-guest
# Dispatch: the machine-role entrypoint hands ANY '-box' role to the tenant
# mechanism on the family suffix — enumerating them would re-chain template
# velocity to rig edits, the exact coupling #110 removes.
check "bootstrap: tenant roles dispatch through bootstrap.sh" 0 "Box TENANT roles" \
  "$ROOT/commands/bootstrap.sh" claude-box --help
check "bootstrap: an unheard-of '-box' role still dispatches (zero code changes)" 0 "Box TENANT roles" \
  "$ROOT/commands/bootstrap.sh" scratch-box --help

# Machine roles use the same resolved registry but remain table-compatible:
# loading happens before flag parsing, so an explicit flag overrides the
# definition exactly as it overrides a built-in row.
check "machine template: traits load from the local registry" 2 "join=login" \
  env RIG_TEMPLATES_DIR="$TPL_FIX" TS_AUTHKEY=x \
  "$ROOT/commands/bootstrap.sh" scratch-server --no-users
if [ "$(id -u)" -ne 0 ]; then
  check "machine template: a flag overrides the loaded trait" 1 "must run as root" \
    env RIG_TEMPLATES_DIR="$TPL_FIX" TS_AUTHKEY=x \
    "$ROOT/commands/bootstrap.sh" scratch-server --no-users --join authkey
fi
check "machine template: invalid ROOT_DOOR is refused by key" 2 "ROOT_DOOR" \
  env RIG_TEMPLATES_DIR="$TPL_FIX" \
  "$ROOT/commands/bootstrap.sh" baddoor-server --no-users
check "machine template: unknown role lists machine definitions" 2 "scratch-server" \
  env RIG_TEMPLATES_DIR="$TPL_FIX" "$ROOT/commands/bootstrap.sh" absent-server
check "machine template: unknown role names the resolved source" 2 "RIG_TEMPLATES_DIR" \
  env RIG_TEMPLATES_DIR="$TPL_FIX" "$ROOT/commands/bootstrap.sh" absent-server
check "machine template: a registry role cannot shadow a built-in" 2 "unset TS_AUTHKEY" \
  env RIG_TEMPLATES_DIR="$TPL_FIX" TS_AUTHKEY=x \
  "$ROOT/commands/bootstrap.sh" workstation --no-users

# The tenant marker guard (#83), against marker FIXTURES (never the harness
# machine's real /etc/rig/role): converging a tenant onto a machine-role box or a
# VM host (host=yes) refuses for every tenant — and names the staging PAIR,
# because whoever hits it has the halves confused: the guest (staging-box), the metal
# (staging-server). An agent tenant refuses ANY machine-role box; staging-box
# tolerates exactly the workload-joined guest (root-door=open host=no) and refuses the
# rest. These need no registry: the guards run before the resolution, so a
# poisoning converge is refused even when the registry is unreachable.
TEN_FIX="$(mktemp -d)"
printf 'role=workload-server root-door=open host=no join=authkey\n' > "$TEN_FIX/machine"
printf 'role=custom root-door=closed host=no join=authkey\n'        > "$TEN_FIX/closed"
printf 'role=staging-server root-door=open host=yes join=authkey\n' > "$TEN_FIX/host"
printf 'role=workload class=server\n'                               > "$TEN_FIX/pre77-machine"
printf 'role=dev class=human\n'                                     > "$TEN_FIX/pre77-human"
printf 'role=claude-box tenant=yes host=no\n'                  > "$TEN_FIX/tenant"
check "tenant: staging-box refuses a closed-door machine box" 1 "root door is not open" \
  env RIG_ROLE_MARKER="$TEN_FIX/closed" "$ROOT/commands/bootstrap-tenant.sh" staging-box
check "tenant: refuses a host=yes box (a VM host is never a guest)" 1 "hosts VMs" \
  env RIG_ROLE_MARKER="$TEN_FIX/host" "$ROOT/commands/bootstrap-tenant.sh" claude-box
check "tenant: the host refusal sends you to the metal half of the pair" 1 "staging-server" \
  env RIG_ROLE_MARKER="$TEN_FIX/host" "$ROOT/commands/bootstrap-tenant.sh" staging-box
check "tenant: an agent role refuses a machine-role box" 1 "never tailnet machines" \
  env RIG_ROLE_MARKER="$TEN_FIX/machine" "$ROOT/commands/bootstrap-tenant.sh" claude-box
# The tenant guard's compat read (#77). This guard asks "does this marker name
# a root-door policy?" through the resolver, so the pre-#77 spelling counts —
# pattern-matching one spelling would fail OPEN here: the marker stops looking
# like a machine's, the refusal never fires, and a tenant converge clobbers a
# live fleet box's marker.
check "tenant: an agent role refuses a PRE-#77 machine marker" 1 "never tailnet machines" \
  env RIG_ROLE_MARKER="$TEN_FIX/pre77-machine" "$ROOT/commands/bootstrap-tenant.sh" claude-box
check "tenant: staging-box refuses a PRE-#77 closed-door machine box" 1 "root door is not open" \
  env RIG_ROLE_MARKER="$TEN_FIX/pre77-human" "$ROOT/commands/bootstrap-tenant.sh" staging-box
# ...and the guard needs no registry: an unreachable RIG_TEMPLATES_DIR must
# not stop a refusal that protects a live fleet box.
check "tenant: the marker guard fires even with the registry unreachable" 1 "never tailnet machines" \
  env RIG_ROLE_MARKER="$TEN_FIX/machine" RIG_TEMPLATES_DIR=/nonexistent/registry \
  "$ROOT/commands/bootstrap-tenant.sh" claude-box

# The definition surface (#110), offline via RIG_TEMPLATES_DIR. An unknown
# role's refusal LISTS what the resolved source actually contains and names
# the source — a misconfigured RIG_TEMPLATES_REPO/_REF/_DIR must be visible
# in the error rather than looking like a typo.
check "tenant: unknown role lists the resolved registry" 2 "scratch-box" \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" \
  "$ROOT/commands/bootstrap-tenant.sh" nosuch-box
check "tenant: the unknown-role refusal names the source" 2 "RIG_TEMPLATES_DIR" \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" \
  "$ROOT/commands/bootstrap-tenant.sh" nosuch-box
check "tenant: an unreadable RIG_TEMPLATES_DIR refuses loudly" 2 "not a directory" \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR=/nonexistent/registry \
  "$ROOT/commands/bootstrap-tenant.sh" scratch-box
# _DIR outranks _REF: with both set, resolution must not touch the network —
# provable offline exactly because a fetch attempt would fail here.
check "tenant: RIG_TEMPLATES_DIR outranks RIG_TEMPLATES_REF" 2 "scratch-box" \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" RIG_TEMPLATES_REF=some-branch \
  "$ROOT/commands/bootstrap-tenant.sh" nosuch-box
# A malformed definition is refused at bootstrap BY KEY (the box.env
# discipline: parsed, never sourced — so a template cannot execute arbitrary
# shell through the data file). The registry CI's lint is the other gate;
# this one protects a mint served through a source CI never saw.
check "tenant: an unknown key is refused by name" 2 "unknown key: COLOR" \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" \
  "$ROOT/commands/bootstrap-tenant.sh" badkey-box
check "tenant: a missing required key is refused by name" 2 "missing required key: CLI_NAME" \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" \
  "$ROOT/commands/bootstrap-tenant.sh" missing-box
check "tenant: a non-KEY=\"value\" line is refused with its line number" 2 'not KEY="value"' \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" \
  "$ROOT/commands/bootstrap-tenant.sh" garbled-box
check "tenant: a bad NEEDS_NODE value is refused by key" 2 "NEEDS_NODE" \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" \
  "$ROOT/commands/bootstrap-tenant.sh" badnode-box
check "tenant: an option riding APT_EXTRAS is refused by key" 2 "APT_EXTRAS" \
  env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" \
  "$ROOT/commands/bootstrap-tenant.sh" badapt-box
if [ "$(id -u)" -ne 0 ]; then
  # RIG_ROLE_MARKER pinned to the absent fixture: the marker guard runs before
  # the root check, and the harness machine may carry a real /etc/rig/role.
  # Reaching the root check proves the whole pre-root surface passed: the
  # name, the flags, the guard, the resolution AND the parse.
  check "tenant: a valid definition parses, refuses non-root" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR="$TPL_FIX" \
    "$ROOT/commands/bootstrap-tenant.sh" scratch-box
  check "tenant: staging-box needs no registry at all" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/absent" RIG_TEMPLATES_DIR=/nonexistent/registry \
    "$ROOT/commands/bootstrap-tenant.sh" staging-box
  check "tenant: staging-box tolerates a workload-joined guest's marker" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/machine" "$ROOT/commands/bootstrap-tenant.sh" staging-box
  # ...and the same guest joined before #77: reaching the root check (rather
  # than a marker refusal) is what proves the tolerance survived the rename.
  check "tenant: staging-box tolerates a PRE-#77 workload-joined guest" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/pre77-machine" "$ROOT/commands/bootstrap-tenant.sh" staging-box
  check "tenant: a tenant marker re-runs fine (convergence)" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/tenant" RIG_TEMPLATES_DIR="$TPL_FIX" \
    "$ROOT/commands/bootstrap-tenant.sh" scratch-box
else
  echo "skip: tenant non-root refusals (running as root)"
fi
rm -rf "$TEN_FIX"

# The same definition served from a REF (tarball fetch, curl stubbed — the
# release.sh discipline) and from a local DIR must resolve to identical
# converge inputs: the parsed TPL_* table and the rendered context file are
# everything the mechanism consumes, so identical inputs ARE the identical
# converge (#110's acceptance criterion, provable offline).
TPL_WORK="$(mktemp -d)"
mkdir -p "$TPL_WORK/bin" "$TPL_WORK/stage/rig-templates-testref"
cp -r "$TPL_FIX"/. "$TPL_WORK/stage/rig-templates-testref/"
tar -czf "$TPL_WORK/reg.tar.gz" -C "$TPL_WORK/stage" rig-templates-testref
cat > "$TPL_WORK/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
# stub: invoked as `curl -fsSL <url> -o <out>` by templates_resolve
echo "$2" >> "${CURL_LOG:?}"
cp "${CURL_TARBALL:?}" "$4"
CURLEOF
chmod +x "$TPL_WORK/bin/curl"
# Single quotes deliberate throughout (SC2016): the $-expressions expand in
# the INNER bash, against the sourced lib's state, never in the harness.
# shellcheck disable=SC2016
tpl_inputs_script='set -euo pipefail
  . "$1/commands/lib/templates.sh"
  templates_resolve
  template_parse_env "$REGISTRY_DIR/scratch-box/template.env"
  printf "USER=%s|CTX=%s|CLI=%s|SRC=%s|PATH=%s|NODE=%s|APT=%s\n" \
    "$TPL_USER" "$TPL_CONTEXT_PATH" "$TPL_CLI_NAME" "$TPL_CLI_SRC" \
    "$TPL_PATH_LINE" "$TPL_NEEDS_NODE" "$TPL_APT_EXTRAS"
  render_tenant_context scratch-box "$REGISTRY_DIR/scratch-box/creds.md"'
tpl_from_dir() {   # tpl_from_dir <outfile> — the local-folder path
  env RIG_TEMPLATES_DIR="$TPL_FIX" bash -c "$tpl_inputs_script" _ "$ROOT" > "$1"
}
tpl_from_ref() {   # tpl_from_ref <outfile> — the tarball path, curl stubbed
  env PATH="$TPL_WORK/bin:$PATH" CURL_LOG="$TPL_WORK/curl.log" \
      CURL_TARBALL="$TPL_WORK/reg.tar.gz" RIG_TEMPLATES_REF=testref \
      bash -c "$tpl_inputs_script" _ "$ROOT" > "$1"
}
check "templates: a local DIR resolves and parses" 0 "" tpl_from_dir "$TPL_WORK/from-dir"
check "templates: a REF resolves through the tarball fetch (stubbed curl)" 0 "" \
  tpl_from_ref "$TPL_WORK/from-ref"
check "templates: DIR and REF yield byte-identical converge inputs" 0 "" \
  diff "$TPL_WORK/from-dir" "$TPL_WORK/from-ref"
# The fetch's first candidate is refs/tags — a tag must outrank a branch that
# happens to share its name (install.sh's own precedence, the pin must win).
check "templates: the fetch asks refs/tags first" 0 "/archive/refs/tags/testref.tar.gz" \
  head -n1 "$TPL_WORK/curl.log"
check "templates: the rendered context carries the box#80 guard" 0 "box setup-host" \
  cat "$TPL_WORK/from-dir"
check "templates: the guard says whose host this is not" 0 "not a host you own" \
  cat "$TPL_WORK/from-dir"
check "templates: the guard cites box#80" 0 "box#80" cat "$TPL_WORK/from-dir"
check "templates: the definition's creds paragraph is spliced in" 0 "The scratch vendor paragraph" \
  cat "$TPL_WORK/from-dir"
check "templates: the bootstrap runbook note survives the split" 0 "Bootstrap runbook" \
  cat "$TPL_WORK/from-dir"
# The default ref is the IN-TREE PIN (the BOX_RELEASE discipline, ruled on
# #110: pinned, not main-tracked): exactly one greppable assignment, so a pin
# bump is a one-line PR and the drill can read the pin from an installed tree.
# shellcheck disable=SC2016
check "templates: the pin is one greppable line" 0 "1" \
  bash -c 'grep -c "^RIG_TEMPLATES_PIN=" "$1/commands/lib/templates.sh"' _ "$ROOT"
# shellcheck disable=SC2016
check "templates: unset knobs fall back to the pin" 0 "the in-tree pin" \
  bash -c '. "$1/commands/lib/templates.sh" && templates_source_desc' _ "$ROOT"

# The installed snapshot is found relative to templates.sh itself, so exercise
# it in a copied rig tree: no fixture-only path knob can accidentally make the
# production precedence pass. Poisoned curl makes any network attempt fatal.
mkdir -p "$TPL_WORK/rig/commands/lib"
cp "$ROOT/commands/lib/templates.sh" "$TPL_WORK/rig/commands/lib/templates.sh"
TPL_PIN="$(sed -n 's/^RIG_TEMPLATES_PIN=//p' "$ROOT/commands/lib/templates.sh")"
cp -r "$TPL_FIX" "$TPL_WORK/rig/templates@$TPL_PIN"
cat > "$TPL_WORK/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
echo "poisoned curl: snapshot resolution attempted network I/O" >&2
exit 99
CURLEOF
chmod +x "$TPL_WORK/bin/curl"
# shellcheck disable=SC2016
snapshot_resolve='set -euo pipefail
  . "$1/commands/lib/templates.sh"
  templates_resolve
  printf "%s\n%s\n" "$REGISTRY_DIR" "$(templates_source_desc)"'
check "templates: matching snapshot resolves with poisoned curl" 0 "(snapshot)" \
  env PATH="$TPL_WORK/bin:$PATH" bash -c "$snapshot_resolve" _ "$TPL_WORK/rig"

# A stale directory and an empty current directory are both unusable. The
# poisoned fetch exit is folded into templates_resolve's normal loud refusal;
# the important assertion is that neither path answers as the registry.
mv "$TPL_WORK/rig/templates@$TPL_PIN" "$TPL_WORK/rig/templates@stale-pin"
mkdir "$TPL_WORK/rig/templates@$TPL_PIN"
check "templates: empty matching snapshot falls back to fetch" 1 "cannot fetch" \
  env PATH="$TPL_WORK/bin:$PATH" bash -c "$snapshot_resolve" _ "$TPL_WORK/rig"
rm -rf "$TPL_WORK/rig/templates@$TPL_PIN"
check "templates: stale snapshot is ignored" 1 "cannot fetch" \
  env PATH="$TPL_WORK/bin:$PATH" bash -c "$snapshot_resolve" _ "$TPL_WORK/rig"

# An explicit ref always means a live fetch, even when the matching snapshot
# exists: restore it and prove the poison is reached.
mv "$TPL_WORK/rig/templates@stale-pin" "$TPL_WORK/rig/templates@$TPL_PIN"
check "templates: explicit REF never reads the snapshot" 1 "cannot fetch" \
  env PATH="$TPL_WORK/bin:$PATH" RIG_TEMPLATES_REF=operator-ref \
  bash -c "$snapshot_resolve" _ "$TPL_WORK/rig"

# rig template-lint — the registry repo's CI gate, same schema as the mint's
# parser (rig defines validity; rig-templates CI enforces it on every PR).
check "template-lint: --help exits 0" 0 "usage:" "$ROOT/commands/template-lint.sh" --help
check "template-lint: a directory is required" 2 "role directory required" "$ROOT/commands/template-lint.sh"
check "template-lint: dispatched from bin/rig" 0 "usage:" "$ROOT/bin/rig" template-lint --help
check "template-lint: a valid definition passes" 0 "OK: " "$ROOT/commands/template-lint.sh" "$TPL_FIX/scratch-box"
check "template-lint: an unknown key fails by name" 1 "unknown key: COLOR" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/badkey-box"
check "template-lint: one bad definition fails the whole run" 1 "FAIL: " \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/scratch-box" "$TPL_FIX/badkey-box"
mkdir -p "$TPL_FIX/plain"
cp "$TPL_FIX/scratch-box"/* "$TPL_FIX/plain/"
check "template-lint: a suffix-less role directory is refused (#76)" 1 "family suffix" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/plain"
mkdir -p "$TPL_FIX/noinstall-box"
cp "$TPL_FIX/scratch-box/template.env" "$TPL_FIX/scratch-box/creds.md" "$TPL_FIX/noinstall-box/"
check "template-lint: a missing install.sh is refused by name" 1 "install.sh missing" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/noinstall-box"
mkdir -p "$TPL_FIX/blankcreds-box"
cp "$TPL_FIX/scratch-box/template.env" "$TPL_FIX/scratch-box/install.sh" "$TPL_FIX/blankcreds-box/"
printf '  \n\t\n' > "$TPL_FIX/blankcreds-box/creds.md"
check "template-lint: a blank creds.md is refused by name" 1 "creds.md missing or blank" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/blankcreds-box"
mkdir -p "$TPL_FIX/noshebang-box"
cp "$TPL_FIX/scratch-box/template.env" "$TPL_FIX/scratch-box/creds.md" "$TPL_FIX/noshebang-box/"
printf 'exit 0\n' > "$TPL_FIX/noshebang-box/install.sh"
check "template-lint: an install.sh without a shebang is refused" 1 "no shebang" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/noshebang-box"
check "template-lint: a traits-only machine definition passes" 0 "OK: " \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/scratch-server"
check "template-lint: workstation is the machine-family carve-out" 0 "OK: " \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/workstation"
check "template-lint: machine roles refuse tenant keys" 1 "unknown key: USER" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/tenantkeys-server"
check "template-lint: tenant roles refuse machine keys" 1 "unknown key: ROOT_DOOR" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/machinekeys-box"
check "template-lint: machine roles refuse creds.md" 1 "creds.md is not allowed" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/creds-server"
check "template-lint: machine install.sh requires a shebang" 1 "no shebang" \
  "$ROOT/commands/template-lint.sh" "$TPL_FIX/noshebang-server"
# The install is deliberately after the users phase and its wrapper names both
# role and source. Dynamic execution belongs to the root integration path; the
# non-root offline harness pins the safety ordering and failure contract.
machine_hook_at="$(grep -n 'running install hook for' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
check "machine template: install hook is bootstrap's last convergence phase" 0 "" \
  test "${users_apply_at:-999999}" -lt "${machine_hook_at:-0}"
# shellcheck disable=SC2016
check "machine template: install failure names role and source" 0 "" \
  grep -qF 'install hook failed for role $ROLE from $(templates_source_desc)' "$ROOT/commands/bootstrap.sh"
# shellcheck disable=SC2016
check "machine template: install runs from its definition with RIG_ROLE" 0 "" \
  grep -qF 'cd "$MACHINE_TEMPLATE_DIR" && RIG_ROLE="$ROLE" bash ./install.sh' "$ROOT/commands/bootstrap.sh"
rm -rf "$TPL_FIX" "$TPL_WORK"

# Creds-free BY CONSTRUCTION, provable by absence (box#69's grep-refusal
# idiom): nothing in the tenant mechanism touches the tailnet, prompts, or
# apt-installs incus. A grep that finds nothing (exit 1) is the pass. The
# same absences hold for the templates lib — it fetches DATA, unauthenticated
# by contract, and must never grow a credential to do it.
check "tenant: never touches the tailnet" 1 "" \
  grep -nE 'tailscale|TS_AUTHKEY' "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: non-interactive — nothing prompts" 1 "" \
  grep -nE '\bread -r' "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: never apt-installs incus (box owns the daemon)" 1 "" \
  grep -nE 'apt-get install.* incus' "$ROOT/commands/bootstrap-tenant.sh"
check "templates lib: the fetch carries no credential" 1 "" \
  grep -nE 'Authorization|gh api|GITHUB_TOKEN' "$ROOT/commands/lib/templates.sh"
# The data file is PARSED, never executed: the parse loop reads lines, and
# no source statement may ever reach template.env. Grep-pinned because the
# failure is silent and total — a sourced template.env is arbitrary shell
# running as root at every mint.
check "templates lib: the parser READS template.env line by line" 0 "" \
  grep -qF 'while IFS= read -r line' "$ROOT/commands/lib/templates.sh"
check "templates lib: template.env is never sourced" 1 "" \
  grep -nE '(source|^[[:space:]]*\.)[[:space:]]+[^#]*template\.env' "$ROOT/commands/lib/templates.sh" "$ROOT/commands/bootstrap-tenant.sh"
# staging-box's posture rides the SAME hardening code as the machine roles — the
# shared lib call is the anti-drift property, so pin the call, not the words.
check "tenant: staging-box hardens through the shared sshd lib" 0 "" \
  grep -qE '^[[:space:]]*harden_sshd open$' "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: docker lands via docker's own installer" 0 "" \
  grep -q "get.docker.com" "$ROOT/commands/bootstrap-tenant.sh"
# The #15 lesson pinned: 'box exec' shells read no rc files, so the CLI must
# land on the SYSTEM path — and a claimed install is verified, not trusted:
# it must ANSWER as the tenant user (the grok-box template's scar: linked but
# cannot run). The $CLI/$TENANT_USER are literals we grep for in the script.
# shellcheck disable=SC2016
check "tenant: the agent CLI lands on the system PATH" 0 "" \
  grep -qF '/usr/local/bin/$CLI' "$ROOT/commands/bootstrap-tenant.sh"
# shellcheck disable=SC2016
check "tenant: the CLI install is verified as the tenant user" 0 "" \
  grep -qF 'runuser -l "$TENANT_USER" -c "$CLI --version"' "$ROOT/commands/bootstrap-tenant.sh"
# Ordering is the safety property, as with bootstrap's marker-then-box assert:
# the tenant marker may only describe converges that already happened, so the
# write sits after the context-file converge. Defaults fail closed.
ten_ctx_at="$(grep -n 'agent-context file written' "$ROOT/commands/bootstrap-tenant.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
ten_marker_at="$(grep -nF 'install -m 0644 "$MARKER_TMP" "$MARKER_PATH"' "$ROOT/commands/bootstrap-tenant.sh" | head -n1 | cut -d: -f1)"
check "tenant: the marker write follows the context-file converge" \
  0 "" test "${ten_ctx_at:-999999}" -lt "${ten_marker_at:-0}"
# The write's "is a machine marker already here?" test must go through the
# resolver, not through a pattern match on one spelling (#77). Pinned as a
# byte-grep because the failure it prevents is silent and expensive: a
# spelling-specific test would let a tenant converge CLOBBER a machine marker
# written in the other vocabulary — on a joined workload box that means
# replacing its root-door policy with a tenant line close-root then refuses on.
# shellcheck disable=SC2016
check "tenant: the marker write is gated on the resolved root-door, not a spelling" 0 "" \
  grep -qxF 'if [ -z "$EXISTING_ROOT_DOOR" ]; then' "$ROOT/commands/bootstrap-tenant.sh"
check "coolify: version required, exit 2"  2 "--version"      "$ROOT/commands/coolify-install.sh"
check "coolify: --help exits 0"            0 "usage:"         "$ROOT/commands/coolify-install.sh" --help
check "coolify: version needs value"       2 "needs a value"  "$ROOT/commands/coolify-install.sh" --version
check "coolify: unknown flag exits 2"      2 "unknown flag"   "$ROOT/commands/coolify-install.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "coolify: refuses non-root"        1 "must run as root" "$ROOT/commands/coolify-install.sh" --version 4.1.2
else
  echo "skip: coolify non-root refusal (running as root)"
fi

check "bare coolify backup shows usage, exit 2" 2 "usage:" "$ROOT/bin/rig" coolify backup
check "coolify backup: bad subcommand exits 2"  2 "usage:" "$ROOT/bin/rig" coolify backup frobnicate
check "coolify backup: --help exits 0"          0 "usage:" "$ROOT/commands/coolify-backup-install.sh" --help
check "coolify backup: schedule needs value"    2 "needs a value" "$ROOT/commands/coolify-backup-install.sh" --schedule
check "coolify backup: pg-container needs value" 2 "needs a value" "$ROOT/commands/coolify-backup-install.sh" --pg-container
check "coolify backup: unknown flag exits 2"    2 "unknown flag"  "$ROOT/commands/coolify-backup-install.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "coolify backup: refuses non-root"      1 "must run as root" "$ROOT/commands/coolify-backup-install.sh"
else
  echo "skip: coolify backup non-root refusal (running as root)"
fi

# --- role-marker sanity: coolify verbs off the control plane (#25) -----------
# Both coolify commands read /etc/rig/role and WARN — never die — when the
# marker names a non-control-plane role: the likeliest story is the wrong SSH
# session, but the marker is advisory and must not outrank the operator. The
# warning fires BEFORE the root check (same testability rule as arg errors),
# so a non-root run prints it and then hits the root refusal — provable here
# with RIG_ROLE_MARKER pointed at fixtures (repo precedent: the close-root
# marker gate). Counting fires proves silence too: a control-plane marker, an
# absent marker, and a marker-less box must all stay quiet, because warning on
# absence would nag every pre-marker box on every legitimate run.
marker_warns() { # marker_warns <marker_path> <cmd...> — how many warnings fired
  local marker="$1"; shift
  env RIG_ROLE_MARKER="$marker" "$@" 2>&1 | grep -c "not a control-plane box" || true
}
MARKER_FIX="$(mktemp -d)"
printf 'role=workload-server root-door=open host=no join=authkey\n'    > "$MARKER_FIX/workload"
printf 'role=control-plane-server root-door=open host=no join=authkey\n' > "$MARKER_FIX/control-plane"
printf 'role=control-plane-server\n'                                   > "$MARKER_FIX/bare-control-plane"
# A PRE-#76 marker, verbatim as a real box bootstrapped before the rename
# carries it. This is the one fixture that must keep its old spelling: the
# CHANGELOG promises such a box takes the warning branch and keeps working,
# and until this existed nothing asserted it — every other fixture here was
# renamed with the code, so the migration story was documented and untested.
printf 'role=control-plane class=server host=no join=authkey\n'        > "$MARKER_FIX/pre-rename-cp"
if [ "$(id -u)" -ne 0 ]; then
  check "coolify: warns on a non-control-plane marker" 0 "1" \
    marker_warns "$MARKER_FIX/workload" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify: control-plane marker stays silent" 0 "0" \
    marker_warns "$MARKER_FIX/control-plane" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  # A bare marker line with no trailing traits must read the same as the full
  # one — the guard must not couple to the marker's field formatting.
  check "coolify: a bare 'role=control-plane-server' line (no traits) stays silent" 0 "0" \
    marker_warns "$MARKER_FIX/bare-control-plane" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify: absent marker stays silent (advisory, not a gate)" 0 "0" \
    marker_warns "$MARKER_FIX/absent" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  # The migration story, pinned in both halves: a pre-#76 control plane WARNS
  # (its marker no longer names a role that exists) but is never refused. Both
  # halves matter — a rename that turned this into a refusal would break the
  # exact boxes the CHANGELOG promises keep working, and it would do it on the
  # command that installs the control plane.
  check "coolify: a PRE-#76 'role=control-plane' marker warns (migration)" 0 "1" \
    marker_warns "$MARKER_FIX/pre-rename-cp" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify: ...and is still never refused" 1 "must run as root" \
    env RIG_ROLE_MARKER="$MARKER_FIX/pre-rename-cp" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify backup: a PRE-#76 'role=control-plane' marker warns (migration)" 0 "1" \
    marker_warns "$MARKER_FIX/pre-rename-cp" "$ROOT/commands/coolify-backup-install.sh"
  # The warning must stay a warning: the run proceeds past it and stops at the
  # root check (exit 1), never turned into a marker refusal.
  check "coolify: the marker warns but never refuses" 1 "must run as root" \
    env RIG_ROLE_MARKER="$MARKER_FIX/workload" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify backup: warns on a non-control-plane marker" 0 "1" \
    marker_warns "$MARKER_FIX/workload" "$ROOT/commands/coolify-backup-install.sh"
  check "coolify backup: control-plane marker stays silent" 0 "0" \
    marker_warns "$MARKER_FIX/control-plane" "$ROOT/commands/coolify-backup-install.sh"
  check "coolify backup: the marker warns but never refuses" 1 "must run as root" \
    env RIG_ROLE_MARKER="$MARKER_FIX/workload" "$ROOT/commands/coolify-backup-install.sh"
else
  echo "skip: coolify role-marker warning checks (running as root)"
fi
rm -rf "$MARKER_FIX"
# Root runs skip the live checks above, so also pin the warning's presence in
# both shipped scripts — a deleted advisory cannot ship green (repo precedent:
# the staging/runner tag greps).
check "coolify: marker warning present in the shipped script" 0 "" \
  grep -q "not a control-plane box" "$ROOT/commands/coolify-install.sh"
check "coolify backup: marker warning present in the shipped script" 0 "" \
  grep -q "not a control-plane box" "$ROOT/commands/coolify-backup-install.sh"

# --- rig db (ad-hoc dump/restore) -------------------------------------------
check "bare db shows usage, exit 2"       2 "usage:" "$ROOT/bin/rig" db
check "db --help exits 0"                 0 "usage:" "$ROOT/bin/rig" db --help
check "db bad subcommand exits 2"         2 "usage:" "$ROOT/bin/rig" db frobnicate
check "db dump: --help exits 0"           0 "usage:" "$ROOT/commands/db.sh" dump --help
check "db dump: container required, exit 2" 2 "needs a container" "$ROOT/commands/db.sh" dump
check "db dump: unknown flag exits 2"     2 "unknown flag" "$ROOT/commands/db.sh" dump --nope
check "db restore: artifact required, exit 2" 2 "needs an artifact" "$ROOT/commands/db.sh" restore
check "db restore: container required, exit 2" 2 "needs a target container" \
  "$ROOT/commands/db.sh" restore /tmp/whatever.sql.gz
check "db restore: unknown flag exits 2"  2 "unknown flag" "$ROOT/commands/db.sh" restore --nope
# Artifact existence is checked BEFORE docker/root, so a fat-fingered path fails
# clearly and cheaply — and is testable here without root or a live container.
check "db restore: missing artifact fails before the docker/root path" \
  1 "artifact not found" "$ROOT/commands/db.sh" restore /no/such/artifact.sql.gz somecontainer --yes

# The two DB invariants live as embedded command strings (single-quoted sh -c),
# not an extractable heredoc, so guard them directly: dropping --no-owner/--no-acl
# breaks every cross-instance restore, and hardcoding a role instead of the
# container's own $POSTGRES_USER/$POSTGRES_DB is wrong on Coolify's randomized
# superuser. ON_ERROR_STOP=1 is what makes a bad restore fail instead of limp.
check "db dump embeds --no-owner --no-acl" 0 "" \
  grep -qF -- "--no-owner --no-acl" "$ROOT/commands/db.sh"
# The $POSTGRES_USER below is a LITERAL we grep for in db.sh (it must read the
# container's env, not the host's) — single quotes are the point here.
# shellcheck disable=SC2016
check "db dump reads the container's own \$POSTGRES_USER/\$POSTGRES_DB" 0 "" \
  grep -qF 'pg_dump -U "$POSTGRES_USER"' "$ROOT/commands/db.sh"
# shellcheck disable=SC2016
check "db restore connects as the container's own \$POSTGRES_USER" 0 "" \
  grep -qF 'psql -U "$POSTGRES_USER"' "$ROOT/commands/db.sh"
check "db restore uses ON_ERROR_STOP=1" 0 "" \
  grep -qF "ON_ERROR_STOP=1" "$ROOT/commands/db.sh"
if [ "$(id -u)" -ne 0 ]; then
  # Valid args, so validation passes and we reach the root guard.
  check "db dump: refuses non-root"       1 "must run as root" "$ROOT/commands/db.sh" dump somecontainer
  # Restore needs a real, non-empty artifact to get PAST the artifact check and
  # reach the root guard; --yes skips the confirm prompt so the check is exit-clean.
  DB_ART="$(mktemp)"; printf 'SELECT 1;\n' > "$DB_ART"
  check "db restore: refuses non-root"    1 "must run as root" \
    "$ROOT/commands/db.sh" restore "$DB_ART" somecontainer --yes
  rm -f "$DB_ART"
else
  echo "skip: db non-root refusals (running as root)"
fi

check "bare runner shows usage, exit 2"  2 "usage:"          "$ROOT/bin/rig" runner
check "runner: --help exits 0"           0 "usage:"          "$ROOT/commands/runner-install.sh" --help
check "runner: repo required, exit 2"    2 "--repo"          "$ROOT/commands/runner-install.sh" --version 2.335.1
check "runner: version needs value"      2 "needs a value"   "$ROOT/commands/runner-install.sh" --repo acme/widgets --version
check "runner: repo needs value"         2 "needs a value"   "$ROOT/commands/runner-install.sh" --repo
check "runner: rejects bad repo slug"    2 "owner/repo"      "$ROOT/commands/runner-install.sh" --repo not-a-slug --version 2.335.1
check "runner: refuses --user root"      2 "must not be root" "$ROOT/commands/runner-install.sh" --repo acme/widgets --version 2.335.1 --user root
check "runner: unknown flag exits 2"     2 "unknown flag"    "$ROOT/commands/runner-install.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "runner: refuses non-root"       1 "must run as root" env RUNNER_TOKEN=x "$ROOT/commands/runner-install.sh" --repo acme/widgets --version 2.335.1
else
  echo "skip: runner non-root refusal (running as root)"
fi

check "runner: bad subcommand exits 2"   2 "usage:"           "$ROOT/bin/rig" runner frobnicate

# --- headless prompts refuse loudly (issue #42) ------------------------------
# The three credential prompts (TS_AUTHKEY, RUNNER_TOKEN, RUNNER_REMOVE_TOKEN)
# used to be bare `read -rsp`: with no tty, read exits non-zero and `set -e`
# ends the script with NO output at all — the drill watched a bootstrap die
# mid-converge with exit 1 and nothing to grep. Each prompt now refuses first,
# naming its variable. The prompts live behind the root check (and, for the
# runner pair, behind a real registration), so the harness cannot reach them
# non-root; grep the guards so a deleted one cannot ship green (repo
# precedent: the login-path tag refusals above).
check "bootstrap: headless TS_AUTHKEY prompt refuses loudly" 0 "" \
  grep -q 'TS_AUTHKEY is unset and stdin is not a tty' "$ROOT/commands/bootstrap.sh"
check "runner install: headless token prompt refuses loudly" 0 "" \
  grep -q 'RUNNER_TOKEN is unset and stdin is not a tty' "$ROOT/commands/runner-install.sh"
check "runner remove: headless token prompt refuses loudly" 0 "" \
  grep -q 'RUNNER_REMOVE_TOKEN is unset and stdin is not a tty' "$ROOT/commands/runner-remove.sh"
# The EOF-at-the-prompt path (Ctrl-D on a real tty) must also die with a last
# word rather than ride set -e into silence: every read is `|| die`-guarded,
# so a bare `read -rsp` (no `||` on its line) must not exist anywhere.
check "prompts: no bare read -rsp remains" 1 "" \
  grep -RE 'read -rsp[^|]*$' "$ROOT/commands/"
# ...and the same sweep, widened on the two axes #68 escaped through (#75).
# That check reads `-rsp` literally and scans commands/ only; #68 was a plain
# `read -r reply` in bin/rig, so it missed on the spelling AND on the path.
# The class is the shape, not the flags: any `read` run as a PLAIN STATEMENT
# under `set -euo pipefail` kills the shell at EOF, before the `case` that
# would have printed the abort — silently, with exit 1, indistinguishable
# from a normal refusal.
#
# So: match `read` at the start of a statement (leading whitespace only),
# whatever its flags or arity, then subtract the two shapes that are safe by
# construction:
#   `||`  — the guard itself (`|| die`, `|| reply=""`, `|| { echo; die … }`).
#           An errexit-exempt read, which is the whole cure.
#   `<<<` — a here-string always supplies a terminating newline, so the read
#           cannot return non-zero. lib/users-config.sh:50/:78 are these.
# `while`/`until`/`if` heads need no subtraction: the anchor already excludes
# them, since `read` is not the first word on those lines. Keep the guard on
# the read's own line — a `\`-continued `||` reads as unguarded here, by
# design, because it is not visible at the point of failure.
unguarded_read() {
  grep -REn '^[[:space:]]*read[[:space:]]' "$ROOT/bin/" "$ROOT/commands/" \
    | grep -Ev '\|\||<<<'
}
check "prompts: no unguarded plain-statement read remains (#75)" 1 "" unguarded_read

# --- runner install: --repo must agree with what the box is already on -------
# The bug: `install --repo B` on a box registered to repo A skipped configure,
# restarted the service on A, and reported success — --repo accepted, validated,
# then ignored. The guard is exercised here through the shared lib, against a
# fixture .runner: reaching it via the CLI needs root AND a really-registered
# runner, neither of which this harness can fabricate.
guard() { # guard <runner_dir> <owner/repo>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/runner-config.sh"
    assert_runner_repo "$2" "$3"' _ "$ROOT" "$1" "$2"
}
REG_DIR="$(mktemp -d)"    # a box registered to acme/alpha
EMPTY_DIR="$(mktemp -d)"  # a box with no runner at all
printf '%s\n' '{"agentId":7,"agentName":"ci-box","gitHubUrl":"https://github.com/acme/alpha","workFolder":"_work"}' \
  > "$REG_DIR/.runner"

check "runner install: refuses a repo the box is not registered to" \
  1 "already registered to https://github.com/acme/alpha" guard "$REG_DIR" acme/beta
check "runner install: the refusal names the repo that was asked for" \
  1 "not https://github.com/acme/beta" guard "$REG_DIR" acme/beta
check "runner install: the refusal points at repoint" \
  1 "rig runner repoint --repo acme/beta" guard "$REG_DIR" acme/beta
# Convergence is the property worth keeping: same repo stays a clean no-op.
check "runner install: the repo it is already on is a no-op" \
  0 "" guard "$REG_DIR" acme/alpha
check "runner install: an unregistered box passes the guard" \
  0 "" guard "$EMPTY_DIR" acme/beta
# A .runner rig cannot read is not a licence to assume it matches.
printf '%s\n' '{"agentName":"ci-box"}' > "$REG_DIR/.runner"
check "runner install: refuses an unreadable registration" \
  1 "names no repository" guard "$REG_DIR" acme/alpha
rm -rf "$REG_DIR" "$EMPTY_DIR"

# --- json_string_array: json_field's array-aware sibling ---------------------
# bootstrap reads `.Self.Tags` (a JSON array) out of `tailscale status --json` to
# assert the tag control GRANTED the node — and a rig box has no jq. Exercise the
# reader against fixture netmaps here, the same shared-lib way the guard above is:
# the bootstrap path that calls it needs a real tailnet this harness cannot fake.
tags() { # tags <file> — prints one tag per line, exactly like the reader
  bash -c 'set -euo pipefail
    . "$1/commands/lib/runner-config.sh"
    json_string_array "$2" Tags' _ "$ROOT" "$1"
}
tags_count() { # tags_count <file> — prints how many tags were read (0 if none)
  bash -c 'set -euo pipefail
    . "$1/commands/lib/runner-config.sh"
    json_string_array "$2" Tags | grep -c . || true' _ "$ROOT" "$1"
}
tags_empty() { # tags_empty <file> — exit 0 iff the reader prints NOTHING
  bash -c 'set -euo pipefail
    . "$1/commands/lib/runner-config.sh"
    [ -z "$(json_string_array "$2" Tags)" ]' _ "$ROOT" "$1"
}
FIX_TAGGED="$(mktemp)"    # Self carries two tags; a peer carries a third
FIX_UNTAGGED="$(mktemp)"  # Self has no Tags key at all — the untagged hazard
FIX_NESTED="$(mktemp)"    # tagged Self carrying a nested Location object
cat > "$FIX_TAGGED" <<'JSON'
{
  "BackendState": "Running",
  "Self": {
    "HostName": "ci-box",
    "Tags": [
      "tag:ci",
      "tag:build"
    ]
  },
  "Peer": {
    "nodekey:abc": {
      "HostName": "coolify-box",
      "Tags": [
        "tag:server"
      ]
    }
  }
}
JSON
# The peers are the point (#160): an untagged Self OMITS its Tags key (Go
# omitempty), and the old document-global reader then fell through into Peer and
# returned tag:server here. Every real tailnet has this shape — untagged Self
# next to tagged peers — which the peerless fixture this replaces never covered.
cat > "$FIX_UNTAGGED" <<'JSON'
{
  "BackendState": "Running",
  "Self": {
    "HostName": "user-owned-box"
  },
  "Peer": {
    "nodekey:aaa": {
      "HostName": "coolify-box",
      "Tags": [
        "tag:server"
      ]
    },
    "nodekey:bbb": {
      "HostName": "ci-box",
      "Tags": [
        "tag:ci"
      ]
    }
  }
}
JSON
# Location is a nested object INSIDE Self (a pointer with omitempty in the real
# netmap): a reader that sliced Self to the next key would end early at its
# closing brace and drop the Tags that follow — the brace counter must not.
cat > "$FIX_NESTED" <<'JSON'
{
  "BackendState": "Running",
  "Self": {
    "HostName": "coolify-box",
    "Location": {
      "Country": "Croatia",
      "CountryCode": "HR"
    },
    "Tags": [
      "tag:server",
      "tag:prod"
    ]
  },
  "Peer": {
    "nodekey:abc": {
      "HostName": "ci-box",
      "Tags": [
        "tag:ci"
      ]
    }
  }
}
JSON
check "json_string_array: reads the first array element" 0 "tag:ci"    tags "$FIX_TAGGED"
check "json_string_array: reads a later array element"   0 "tag:build" tags "$FIX_TAGGED"
# The reader is scoped to the Self object: exactly two elements read proves the
# peer's tag:server did not leak into Self's tags.
check "json_string_array: reads Self's array, not a peer's" 0 "2" tags_count "$FIX_TAGGED"
# An absent key omits itself (Go omitempty), never emits []: empty is the signal
# bootstrap turns into a hard untagged-key refusal, so it must read as empty here.
check "json_string_array: absent Tags key prints nothing" 0 "" tags_empty "$FIX_UNTAGGED"
# Regression, #160: with tagged peers present, an untagged Self must STILL read
# empty — pre-fix this returned the peer's tag:server, false-refusing every
# login join and false-verifying untagged authkey joins as tagged.
check "json_string_array: untagged Self + tagged peers reads empty (#160)" \
  0 "" tags_empty "$FIX_UNTAGGED"
check "json_string_array: nested Location does not truncate Self's tags" \
  0 "2" tags_count "$FIX_NESTED"
check "json_string_array: reads past a nested object to a later element" \
  0 "tag:prod" tags "$FIX_NESTED"
rm -f "$FIX_TAGGED" "$FIX_UNTAGGED" "$FIX_NESTED"

# The guard is only worth something if it runs BEFORE the box is touched: the
# token prompt, the download, configure and svc.sh start all come after it.
# Ordering is the whole fix, so assert it rather than trust it.
# Matches the CALL, not the word: the comment above it mentions assert_runner_repo
# too, and a plain grep would keep finding that after the call itself was deleted.
# The defaults fail closed, so a guard that is gone cannot read as one that merely
# sits early in the file.
guard_at="$(grep -nE '^[[:space:]]*assert_runner_repo ' "$ROOT/commands/runner-install.sh" | head -n1 | cut -d: -f1)"
start_at="$(grep -n 'svc.sh start' "$ROOT/commands/runner-install.sh" | head -n1 | cut -d: -f1)"
check "runner install: the repo guard precedes svc.sh start" \
  0 "" test "${guard_at:-999999}" -lt "${start_at:-0}"

check "runner status: --help exits 0"        0 "usage:"           "$ROOT/commands/runner-status.sh" --help
check "runner status: user needs value"      2 "needs a value"    "$ROOT/commands/runner-status.sh" --user
check "runner status: refuses --user root"   2 "must not be root" "$ROOT/commands/runner-status.sh" --user root
check "runner status: unknown flag exits 2"  2 "unknown flag"     "$ROOT/commands/runner-status.sh" --nope

check "runner remove: --help exits 0"        0 "usage:"           "$ROOT/commands/runner-remove.sh" --help
check "runner remove: user needs value"      2 "needs a value"    "$ROOT/commands/runner-remove.sh" --user
check "runner remove: refuses --user root"   2 "must not be root" "$ROOT/commands/runner-remove.sh" --user root
check "runner remove: unknown flag exits 2"  2 "unknown flag"     "$ROOT/commands/runner-remove.sh" --nope

check "runner repoint: --help exits 0"       0 "usage:"           "$ROOT/commands/runner-repoint.sh" --help
check "runner repoint: repo required"        2 "--repo"           "$ROOT/commands/runner-repoint.sh"
check "runner repoint: repo needs value"     2 "needs a value"    "$ROOT/commands/runner-repoint.sh" --repo
check "runner repoint: rejects bad slug"     2 "owner/repo"       "$ROOT/commands/runner-repoint.sh" --repo not-a-slug
check "runner repoint: labels need value"    2 "needs a value"    "$ROOT/commands/runner-repoint.sh" --repo acme/widgets --labels
check "runner repoint: refuses --user root"  2 "must not be root" "$ROOT/commands/runner-repoint.sh" --repo acme/widgets --user root
check "runner repoint: unknown flag exits 2" 2 "unknown flag"     "$ROOT/commands/runner-repoint.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "runner status: refuses non-root"  1 "must run as root" "$ROOT/commands/runner-status.sh"
  check "runner remove: refuses non-root"  1 "must run as root" \
    env RUNNER_REMOVE_TOKEN=x "$ROOT/commands/runner-remove.sh"
  # --local too: the token-free path must still not be runnable by the runner user.
  check "runner remove: --local refuses non-root" 1 "must run as root" \
    "$ROOT/commands/runner-remove.sh" --local
  check "runner repoint: refuses non-root" 1 "must run as root" \
    env RUNNER_REMOVE_TOKEN=x RUNNER_TOKEN=y "$ROOT/commands/runner-repoint.sh" --repo acme/widgets
else
  echo "skip: runner status/remove/repoint non-root refusals (running as root)"
fi

# ---------------------------------------------------------------------------
# rig platform (#64). Unusually testable for this repo: it needs no root, no
# network and no fixtures, and it WRITES NOTHING — so unlike every other
# command here the harness can RUN it for real on the machine running the
# tests and assert on the actual answer, instead of proving arg-parse
# refusals and grepping the rest.
# ---------------------------------------------------------------------------
check "platform: --help exits 0"           0 "usage:"      "$ROOT/commands/platform.sh" --help
check "platform: unknown flag exits 2"     2 "unknown flag" "$ROOT/commands/platform.sh" --nope
check "platform: dispatches through bin/rig" 0 "PLATFORM"  "$ROOT/bin/rig" platform

# The real run: exit 0 and every field present, as the running user.
check "platform: runs as this user, exit 0" 0 "PLATFORM" "$ROOT/bin/rig" platform
for f in HOSTNAME ID OS KERNEL CPU MEMORY DISK VIRT; do
  check "platform: reports $f" 0 "$f" "$ROOT/bin/rig" platform
done
# Not just the labels — the VALUES have to describe THIS machine. uname -r and
# the hostname are the two the harness can independently compute and compare,
# which is what separates "it printed a table" from "it read the machine".
check "platform: KERNEL is this kernel"   0 "$(uname -r)" "$ROOT/bin/rig" platform
check "platform: HOSTNAME is this host"   0 "$(uname -n)" "$ROOT/bin/rig" platform
# MemAvailable/df rendered, not left as the 'unknown' fallback: a numfmt or
# /proc parse that silently broke would still print the labels above.
check "platform: MEMORY carries real numbers" 0 "total," "$ROOT/bin/rig" platform

# Provenance degrades on a machine rig never converged — #61's manifest does
# not exist yet, so 'not bootstrapped' is the state of the world today and the
# command must ship complete without it. Both paths driven against fixtures.
PLATWORK="$(mktemp -d)"
# THE INTEGRATION CONTRACT (#61, found in #74 review): these fixtures carry
# #61's documented schema VERBATIM — schema/bootstrapped_by/bootstrapped_at/
# converged_by/converged_at. An earlier draft of this reader invented `version`
# and `bootstrapped`, which no writer would ever have produced: the command
# would have rendered 'unknown' forever the day #61 landed, and nothing here
# would have said so. Keep these keys in step with #61; that is the point.
printf 'schema=1\nbootstrapped_by=0.4.0\nbootstrapped_at=2026-07-19T14:24:51Z\nconverged_by=0.6.0\nconverged_at=2026-08-02T09:11:03Z\n' > "$PLATWORK/manifest"
check "platform: no manifest reads 'not bootstrapped'" 0 "RIG        not bootstrapped" \
  env RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
check "platform: no role marker reads 'not bootstrapped'" 0 "ROLE       not bootstrapped" \
  env RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# A manifest that DOES exist is read, never written — the forward-compatible
# half, so #61 landing needs no change here.
check "platform: reads #61's converged_by/at" 0 "CONVERGED  0.6.0, 2026-08-02T09:11:03Z" \
  env RIG_MANIFEST="$PLATWORK/manifest" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
check "platform: reads #61's bootstrapped_by/at" 0 "BOOTSTRAP  0.4.0, 2026-07-19T14:24:51Z" \
  env RIG_MANIFEST="$PLATWORK/manifest" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# A FRESH bootstrap carries both pairs with EQUAL values — #61 is explicit
# ("On a fresh machine both pairs are written with equal values"); rule 2 only
# suppresses converged_* churn on a later same-version re-run. So equal dates
# are the never-re-converged case and must render as themselves, not be
# special-cased into looking unset.
printf 'schema=1\nbootstrapped_by=0.4.0\nbootstrapped_at=2026-07-19T14:24:51Z\nconverged_by=0.4.0\nconverged_at=2026-07-19T14:24:51Z\n' > "$PLATWORK/manifest-fresh"
check "platform: a fresh bootstrap shows both pairs equal (#61)" 0 "CONVERGED  0.4.0, 2026-07-19T14:24:51Z" \
  env RIG_MANIFEST="$PLATWORK/manifest-fresh" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# A manifest missing converged_* is therefore NOT a fresh box — no writer
# produces that — so it is partial or hand-edited. Degrade loudly rather than
# backfilling from birth, which would invent a convergence that never happened.
printf 'schema=1\nbootstrapped_by=0.4.0\nbootstrapped_at=2026-07-19T14:24:51Z\n' > "$PLATWORK/manifest-partial"
check "platform: a partial manifest says so, never infers from birth" 0 "CONVERGED  not recorded" \
  env RIG_MANIFEST="$PLATWORK/manifest-partial" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# A newer schema renders what it recognises and says the rest is unreadable,
# rather than pretending a partial read is the whole truth.
printf 'schema=2\nbootstrapped_by=9.9.9\nbootstrapped_at=2027-01-01T00:00:00Z\n' > "$PLATWORK/manifest-v2"
check "platform: a newer schema is named, not silently half-read" 0 "schema=2 is newer" \
  env RIG_MANIFEST="$PLATWORK/manifest-v2" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# A manifest carrying none of #61's keys is reported as such — the pre-#61 or
# corrupt case, distinct from both 'absent' and 'read fine'.
printf 'somethingelse=1\n' > "$PLATWORK/manifest-alien"
check "platform: an unrecognised manifest is not read as empty" 0 "no recognised fields" \
  env RIG_MANIFEST="$PLATWORK/manifest-alien" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# ...including one whose last line has no trailing newline: `read` returns 1 at
# EOF even having filled the variables, so an unguarded loop drops that line
# silently — the timestamp would vanish while the version still rendered. #61's
# writer must not have to know this reader's tolerances (found in #74 review).
printf 'schema=1\nbootstrapped_by=0.4.0\nbootstrapped_at=2026-07-19T14:24:51Z' > "$PLATWORK/manifest-nonl"
check "platform: reads a manifest with no trailing newline" 0 "BOOTSTRAP  0.4.0, 2026-07-19T14:24:51Z" \
  env RIG_MANIFEST="$PLATWORK/manifest-nonl" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
printf 'role=dev class=human host=yes join=authkey\n' > "$PLATWORK/role"
check "platform: renders the role marker's traits" 0 "dev (class=human host=yes join=authkey)" \
  env RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/role" "$ROOT/bin/rig" platform

# --- identity (#95): ID names the machine, HOSTNAME names the slot ----------
# Everything below drives RIG_MACHINE_ID fixtures, so the suite neither
# depends on nor leaks the machine-id of whatever box runs it.
# THE PINNED DERIVATION: sha256("rig-machine-id:<machine-id>") → first 32 hex
# rendered 8-4-4-4-12. The literal below is that digest computed OUTSIDE the
# implementation. This exact-match is what keeps every machine's identity
# stable: a refactor that changes the prefix, the hash or the slicing renames
# the whole fleet at once, and nothing but this line would notice.
# RIG_MANIFEST/RIG_ROLE_MARKER point at the absent fixture on purpose — this
# doubles as the unconverged-machine case: ID must render with no manifest
# and no role marker, because a minted-at-bootstrap id was #95's rejected
# Option B and pre-bootstrap usefulness is the property that rejected it.
printf '0123456789abcdef0123456789abcdef\n' > "$PLATWORK/machine-id"
check "platform: ID is the pinned derivation, manifest-free (#95)" 0 "ID         cd9fb802-1493-2336-d027-7955f328bcd8" \
  env RIG_MACHINE_ID="$PLATWORK/machine-id" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# Determinism asserted, not assumed: two runs over the same input agree.
# (Reboot-stability follows — the id is a pure function of the file content.)
ID_A="$(env RIG_MACHINE_ID="$PLATWORK/machine-id" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform | awk '$1=="ID" {print $2}')"
ID_B="$(env RIG_MACHINE_ID="$PLATWORK/machine-id" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform | awk '$1=="ID" {print $2}')"
check "platform: ID is deterministic across runs" 0 "" test "$ID_A" = "$ID_B"
printf '%s\n' "$ID_A" > "$PLATWORK/idval"
check "platform: ID is UUID-shaped (8-4-4-4-12 hex)" 0 "" \
  grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$PLATWORK/idval"
# A different machine-id yields a different id — pinned exactly rather than
# asserted merely unequal, so a broken extraction cannot pass as "different".
printf 'ffffffffffffffffffffffffffffffff\n' > "$PLATWORK/machine-id-2"
check "platform: ID changes when the machine-id changes" 0 "ID         65441a65-bf82-8c75-b610-26e68a768bd3" \
  env RIG_MACHINE_ID="$PLATWORK/machine-id-2" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# THE CONFIDENTIALITY PROPERTY — the whole reason the derivation exists, and
# the one a future refactor is most likely to lose: the raw machine-id never
# appears anywhere in the output. machine-id(5) asks exactly this.
env RIG_MACHINE_ID="$PLATWORK/machine-id" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" \
  "$ROOT/bin/rig" platform > "$PLATWORK/platout" 2>&1
check "platform: the raw machine-id never appears in the output" 1 "" \
  grep -qF '0123456789abcdef0123456789abcdef' "$PLATWORK/platout"
# An EMPTY machine-id must take the unavailable path, never be hashed:
# sha256("rig-machine-id:") renders as the literal below, and hashing nothing
# would hand every such machine the SAME id — the worst possible failure for
# an identity field. Images do ship the file empty (machine-id(5) first-boot
# semantics), so this is a real path, not a defensive one.
: > "$PLATWORK/machine-id-empty"
check "platform: an empty machine-id says why, exit 0" 0 "ID         unavailable" \
  env RIG_MACHINE_ID="$PLATWORK/machine-id-empty" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
env RIG_MACHINE_ID="$PLATWORK/machine-id-empty" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" \
  "$ROOT/bin/rig" platform > "$PLATWORK/platout-empty" 2>&1
check "platform: empty machine-id is never hashed (no collision id)" 1 "" \
  grep -qF 'ddb56c2f-0df1-0ab0-1c12-371b1d32e34e' "$PLATWORK/platout-empty"
check "platform: empty machine-id — every other field still renders" 0 "HOSTNAME" \
  env RIG_MACHINE_ID="$PLATWORK/machine-id-empty" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# Missing file: same degradation, named reason, never an empty field.
check "platform: a missing machine-id says why, exit 0" 0 "ID         unavailable (no " \
  env RIG_MACHINE_ID="$PLATWORK/absent" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform
# 'uninitialized' is machine-id(5)'s other not-yet-set sentinel — hashing it
# would collide every first-boot image exactly like the empty case.
printf 'uninitialized\n' > "$PLATWORK/machine-id-uninit"
check "platform: an 'uninitialized' machine-id is not hashed" 0 "ID         unavailable ($PLATWORK/machine-id-uninit is uninitialized)" \
  env RIG_MACHINE_ID="$PLATWORK/machine-id-uninit" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform

# The defining property: it writes NOTHING. Not the manifest it just reported
# missing, not the marker, not a cached id (#95's Option A stores nothing),
# not anything else in the fixture directory — the whole design rests on
# this, so assert it rather than trust it.
env RIG_MACHINE_ID="$PLATWORK/absent" RIG_MANIFEST="$PLATWORK/absent" RIG_ROLE_MARKER="$PLATWORK/absent" "$ROOT/bin/rig" platform >/dev/null 2>&1
check "platform: writes nothing (no manifest created)" 1 "" test -e "$PLATWORK/absent"
rm -rf "$PLATWORK"

check "bare users shows usage, exit 2"    2 "usage:"        "$ROOT/bin/rig" users
check "users: bad subcommand exits 2"     2 "usage:"        "$ROOT/bin/rig" users frobnicate

check "users apply: --help exits 0"       0 "usage:"        "$ROOT/commands/users-apply.sh" --help
check "users apply: --file required"      2 "--file"        "$ROOT/commands/users-apply.sh"
check "users apply: --file needs value"   2 "needs a value" "$ROOT/commands/users-apply.sh" --file
check "users apply: missing file exits 2" 2 "cannot read"   "$ROOT/commands/users-apply.sh" --file /nonexistent/users
check "users apply: unknown flag exits 2" 2 "unknown flag"  "$ROOT/commands/users-apply.sh" --nope
check "users status: --help exits 0"      0 "usage:"        "$ROOT/commands/users-status.sh" --help

# --- users file refusal matrix, through the sourced parser -------------------
# Reaching the parser via the CLI stops at the root check; it is pure and
# sourceable on purpose (repo precedent: assert_runner_repo, json_string_array),
# so the refusals are proven here against fixtures, non-root and network-free.
parse() { # parse <file> — the users-file parser, exactly as apply runs it
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    parse_users_file "$2"' _ "$ROOT" "$1"
}
FIX_OK="$(mktemp)"   # two operators; dan carries a second key on a repeat line
FIX_BAD="$(mktemp)"  # rewritten per refusal below
cat > "$FIX_OK" <<'USERS'
# fleet operators
dan      admin,box      ssh-ed25519 AAAAC3fixture dan@laptop
dan      admin,box      ssh-ed25519 AAAAC3second dan@desk

maria    rig            ssh-ed25519 AAAAC3fixture maria@mac
USERS
printf '%s\n' 'maria ops ssh-ed25519 AAAA maria@mac' > "$FIX_BAD"
check "users parser: unknown role names the valid set" 1 "valid roles: admin rig box" parse "$FIX_BAD"
printf '%s\n' 'dan admin ssh-ed25519 AAAA a' 'dan admin,box ssh-ed25519 BBBB b' > "$FIX_BAD"
check "users parser: differing roles across one user's lines" 1 "roles must be identical" parse "$FIX_BAD"
printf '%s\n' 'root admin ssh-ed25519 AAAA r' > "$FIX_BAD"
check "users parser: root is refused" 1 "not a rig-managed user" parse "$FIX_BAD"
printf '%s\n' 'dan admin' > "$FIX_BAD"
check "users parser: malformed line is refused" 1 "malformed" parse "$FIX_BAD"
# Usernames are validated in the same one-pass refusal matrix: 'fo|o' would
# corrupt the parser's own '|'-delimited stream (user 'fo', garbage keys), and
# a leading '-' reads as a useradd flag mid-convergence. The refusal names the
# line and the rule, like every other parser refusal.
printf '%s\n' 'fo|o admin ssh-ed25519 AAAA x' > "$FIX_BAD"
check "users parser: '|' in a username is refused"     1 "invalid username" parse "$FIX_BAD"
check "users parser: the username refusal names the line" 1 "line 1"        parse "$FIX_BAD"
printf '%s\n' '-dan admin ssh-ed25519 AAAA x' > "$FIX_BAD"
check "users parser: leading-dash username is refused" 1 "invalid username" parse "$FIX_BAD"
check "users parser: valid file emits dan (both keys' roles agree)" \
  0 "dan|admin,box|ssh-ed25519 AAAAC3second dan@desk" parse "$FIX_OK"
check "users parser: valid file emits maria too" 0 "maria|rig|ssh-ed25519" parse "$FIX_OK"
# ALL errors in ONE pass: a bad file costs one fix cycle, not one per error.
# A single invocation, both messages asserted from its one stderr.
printf '%s\n' 'root admin ssh-ed25519 AAAA r' 'maria ops ssh-ed25519 AAAA m' > "$FIX_BAD"
MULTI_ERRS="$(mktemp)"
parse "$FIX_BAD" 2> "$MULTI_ERRS"; multi_rc=$?
check "users parser: multi-error file exits 1"       0 "" test "$multi_rc" -eq 1
check "users parser: one run reports the root line"  0 "" grep -q "not a rig-managed user" "$MULTI_ERRS"
check "users parser: same run reports the bad role"  0 "" grep -q "unknown role" "$MULTI_ERRS"
rm -f "$MULTI_ERRS"

# --- '@root': seed the admin's keys from root's own authorized_keys (#17) ----
# The operator provably holds a root private key — they SSHed in with it to
# run apply at all — so seeding root's CURRENT authorized_keys is the one key
# source that cannot lock them out. The parser owns only the token's SHAPE
# (reading /root/.ssh needs root and is apply's business), so the shape is
# proven here: the exact token parses, trailing material is refused, literal
# key lines mix (append semantics), a second '@root' is a duplicate, and root
# cannot seed itself.
printf '%s\n' 'dan admin @root' > "$FIX_BAD"
check "users parser: '@root' is a valid key field" 0 "dan|admin|@root" parse "$FIX_BAD"
printf '%s\n' 'dan admin @root ssh-ed25519 AAAA x' > "$FIX_BAD"
check "users parser: '@root' takes no trailing material" 1 "whole key field" parse "$FIX_BAD"
printf '%s\n' 'dan admin @root' 'dan admin ssh-ed25519 AAAAC3lit dan@desk' > "$FIX_BAD"
check "users parser: '@root' mixes with literal key lines" \
  0 "dan|admin|ssh-ed25519 AAAAC3lit dan@desk" parse "$FIX_BAD"
printf '%s\n' 'dan admin @root' 'dan admin @root' > "$FIX_BAD"
check "users parser: a second '@root' line is a duplicate" 1 "duplicate key line" parse "$FIX_BAD"
printf '%s\n' 'root admin @root' > "$FIX_BAD"
check "users parser: root cannot seed from itself" 1 "not a rig-managed user" parse "$FIX_BAD"
# The empty-seed refusal (root has no authorized_keys) sits behind the root
# check — /root/.ssh is unreadable before it — so grep the die message, the
# same way every root-only refusal in this harness is pinned.
check "users apply: '@root' with a keyless root dies naming the repair" 0 "" \
  grep -q "root has no authorized_keys" "$ROOT/commands/users-apply.sh"

if [ "$(id -u)" -ne 0 ]; then
  # A VALID fixture proves the whole file-validation pass sits before the
  # root check — a parse failure here would exit 2, not 1.
  check "users apply: refuses non-root"  1 "must run as root" "$ROOT/commands/users-apply.sh" --file "$FIX_OK"
  # An '@root' fixture reaching the root check proves the token is parse-pass
  # validation, not a runtime surprise.
  printf '%s\n' 'dan admin @root' > "$FIX_BAD"
  check "users apply: '@root' fixture parses, refuses non-root" 1 "must run as root" \
    "$ROOT/commands/users-apply.sh" --file "$FIX_BAD"
  check "users status: refuses non-root" 1 "must run as root" "$ROOT/commands/users-status.sh"
  # --- the empty-file gate's flag surface (#65) ------------------------------
  # Arg parsing precedes the root check, so flag ACCEPTANCE is provable here:
  # reaching "must run as root" (exit 1) means --yes was taken, and an exit 2
  # "unknown flag" would mean it was not. The gate's behaviour itself is
  # root-only (it reads /etc/rig/users and revokes) and is grep-pinned below.
  check "users apply: --yes is accepted" 1 "must run as root" \
    "$ROOT/commands/users-apply.sh" --file "$FIX_OK" --yes
  # Order-independent: a consent flag that only worked before --file would be
  # a trap for anyone appending it to an existing command line.
  check "users apply: --yes is accepted before --file" 1 "must run as root" \
    "$ROOT/commands/users-apply.sh" --yes --file "$FIX_OK"
  # --yes takes no value: it must not swallow the next argument.
  check "users apply: --yes does not eat the following flag" 2 "unknown flag" \
    "$ROOT/commands/users-apply.sh" --file "$FIX_OK" --yes --nope
  # The env door, same as --yes: RIG_YES is the installer-family contract
  # (bin/rig's uninstall_confirm reads it), so it must not be an unknown-flag
  # equivalent or a parse error either.
  check "users apply: RIG_YES=1 parses" 1 "must run as root" \
    env RIG_YES=1 "$ROOT/commands/users-apply.sh" --file "$FIX_OK"
else
  echo "skip: users non-root refusals (running as root)"
fi
rm -f "$FIX_OK" "$FIX_BAD"

# --- the empty-file gate itself (#65) ----------------------------------------
# The gated path needs root and a populated /etc/rig/users, so the shipped
# script is grep-pinned instead — the house precedent for root-only refusals
# (the '@root' keyless-seed die above, the invoker gate below).
#
# Consent has three doors and no fourth: --yes, RIG_YES, or a y on a TTY.
check "users apply: --yes sets consent" 0 "" \
  grep -qE '^[[:space:]]*--yes\) ASSUME_YES=1' "$ROOT/commands/users-apply.sh"
check "users apply: RIG_YES is the env door for consent" 0 "" \
  grep -qF 'RIG_YES:-' "$ROOT/commands/users-apply.sh"
# The gate is ledger-gated, not file-gated: zero users ALONE is not the
# condition, or it would refuse the empty-ledger no-op the issue calls
# unambiguous. Both halves of the test must be present on the one line.
# The gate condition and the counter are grepped as LITERALS — single quotes
# intended throughout this block, the expansions are the script's own.
# shellcheck disable=SC2016
check "users apply: the gate is zero-users AND a readable ledger" 0 "" \
  grep -qF 'if [ "${#USERS[@]}" -eq 0 ] && [ -r "$LEDGER" ] && [ "$ASSUME_YES" -eq 0 ]; then' \
  "$ROOT/commands/users-apply.sh"
# Counting precedes speaking, so the warning states a real number rather than
# "some users" — and an already-revoked entry is not at risk, which is what
# keeps a second identical run the silent no-op convergence promises.
# shellcheck disable=SC2016
check "users apply: the gate counts before it warns" 0 "" \
  grep -qF 'AT_RISK=$((AT_RISK + 1))' "$ROOT/commands/users-apply.sh"
# shellcheck disable=SC2016
check "users apply: already-revoked ledger entries are not at risk" 0 "" \
  grep -qF '[ "${pstate:-active}" != "revoked" ] || continue' "$ROOT/commands/users-apply.sh"
# shellcheck disable=SC2016
count_at="$(grep -nF 'AT_RISK=$((AT_RISK + 1))' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
warn_at="$(grep -nF 'this users file names ZERO users' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
check "users apply: the count is taken before the message quotes it" \
  0 "" test "${count_at:-999999}" -lt "${warn_at:-0}"
# ...and the floor the count is measured against: ONE at-risk operator is
# enough. That is the gate's entire reason for existing — a box with a single
# operator is the common case for a small team, not an edge case — and nothing
# else here pins it. The condition grep above pins the gate's TRIGGER (zero
# users AND a readable ledger), and the deferred-threshold negative below only
# matches a comparison against a $-variable, so `-gt 1` slips past both and
# silently un-gates exactly the box that most needs the question (#78).
#
# Pinned as a PATTERN, not as the literal line: a correct gate respelled
# `${AT_RISK}` or re-spaced is still a correct gate and must not fail, while
# any floor other than "one is enough" must. `-ge 1` is the same statement in
# other words and is accepted for that reason — which is also why the negative
# pin below is left matching $-variables only, rather than being widened to
# literals: widening it would call that legitimate spelling a threshold.
# shellcheck disable=SC2016
check "users apply: one at-risk operator is enough to gate (#78)" 0 "" \
  grep -qE '^[[:space:]]*if[[:space:]]+\[[[:space:]]+"?\$\{?AT_RISK\}?"?[[:space:]]+(-gt[[:space:]]+0|-ge[[:space:]]+1)[[:space:]]+\][[:space:]]*;[[:space:]]*then[[:space:]]*$' \
  "$ROOT/commands/users-apply.sh"
# No terminal and no consent is a REFUSAL, not an assumed yes and not a hang.
check "users apply: no TTY and no consent exits 2" 0 "" \
  grep -qF 'refusing to revoke every managed operator without --yes' \
  "$ROOT/commands/users-apply.sh"
check "users apply: the no-TTY refusal names RIG_YES as the other yes" 0 "" \
  grep -qF 'no terminal to confirm on; RIG_YES=1 also means yes' \
  "$ROOT/commands/users-apply.sh"
# EOF-safe read (#68's bug class): an unguarded `read -r reply` aborts under
# `set -e` instead of taking the safe default. The || is the whole fix.
check "users apply: the confirm read survives EOF" 0 "" \
  grep -qF 'read -r reply || reply=""' "$ROOT/commands/users-apply.sh"
check "users apply: no unguarded read in the gate" 1 "" \
  grep -nE '^[[:space:]]*read -r reply$' "$ROOT/commands/users-apply.sh"
# The gate must sit BEFORE the revocation loop — a confirmation asked after
# the first account is expired is not a confirmation. Line numbers, defaults
# fail closed, same idiom as the visudo ordering assert.
gate_at="$(grep -nF 'this users file names ZERO users' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
revoke_at="$(grep -nF 'usermod -L -e 1' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
check "users apply: the gate precedes the revocation loop" \
  0 "" test "${gate_at:-999999}" -lt "${revoke_at:-0}"
# Scope guard, the mirror of the #57 one above: this is a CONFIRMATION, and
# apply must not have grown bootstrap's flat refusal of an empty file. A grep
# that finds nothing is the pass — the repo's negative-law idiom.
check "users apply: an empty file is still a legal de-provisioning input (gated, not refused)" 1 "" \
  grep -nE 'names no users' "$ROOT/commands/users-apply.sh"
# The deferred half of #65: mass revocation below the empty-file bright line
# is NOT gated. The gate's only trigger is a file naming zero users, so no
# CODE line may compare a revocation count against a threshold — comments are
# stripped first, since the scope note beside the gate says the word on
# purpose. Pinned so that adding a threshold is a deliberate edit to a failing
# test rather than a silent contract change.
check "users apply: partial mass revocation stays ungated (#65 open question)" 1 "" \
  grep -nEi '^[[:space:]]*[^#[:space:]].*(threshold|RIG_REVOKE_MAX|AT_RISK[^)]*(-gt|-ge)[[:space:]]*\$)' \
  "$ROOT/commands/users-apply.sh"

# The empty-file gate is reachable only from a caller that can answer it. The
# ONE in-tree caller of apply is bootstrap's users phase, and it refuses a
# zero-user file at pre-flight (#57) — before it ever invokes apply — so no
# in-tree path reaches the gate without a TTY. Pin both halves: if a second
# caller appears, or bootstrap's refusal goes away, this stops being true.
callers="$(grep -rlF 'users-apply.sh' "$ROOT/commands" | grep -v 'users-apply.sh$' || true)"
check "users apply: bootstrap is its only in-tree caller" 0 "" \
  test "$callers" = "$ROOT/commands/bootstrap.sh"
check "users apply: bootstrap refuses a zero-user file before invoking it" \
  0 "" test "$(grep -nF 'names no users' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)" \
  -lt "${users_apply_at:-0}"

# Validate-then-apply: `visudo -c` must pass before anything lands in
# /etc/sudoers.d — a bad drop-in takes down ALL of sudo, locking every admin
# out of the escalation path apply just granted. Assert the order in the file,
# matching the calls rather than comments (repo precedent: the runner-install
# repo-guard ordering check). Defaults fail closed.
visudo_at="$(grep -n 'visudo -c' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
sudoers_at="$(grep -nE 'install .*sudoers\.d/rig-roles' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
check "users apply: visudo -c precedes the sudoers install" \
  0 "" test "${visudo_at:-999999}" -lt "${sudoers_at:-0}"

# The invoker gate: %rig's sudoers rule is binary-scoped (NOPASSWD for
# /usr/local/bin/rig, any args), so without a gate `sudo rig users apply
# --file <me-as-admin>` turns role rig root-equivalent through this very
# command. Exercising it needs a real SUDO_USER and real groups, so grep the
# refusal in both identity-management commands (repo precedent: the
# staging/runner tag greps).
check "users apply: invoker gate refusal is present" 0 "" \
  grep -q "changes who holds root" "$ROOT/commands/users-apply.sh"
check "users close-root: invoker gate refusal is present" 0 "" \
  grep -q "changes who holds root" "$ROOT/commands/users-close-root.sh"
# Offboarding must revoke SSH, not just the password: a '!'-locked password is
# not a closed door under UsePAM — pubkey auth still works. Expiry is the
# switch PAM actually honors, and the keys are renamed, never deleted
# (convergence never destroys). Needs root + real accounts, so grep both moves.
check "users apply: a dropped user's account is expired, not just locked" 0 "" \
  grep -qF -- "usermod -L -e 1" "$ROOT/commands/users-apply.sh"
check "users apply: revoked keys are renamed, never deleted" 0 "" \
  grep -q "revoked-by-rig" "$ROOT/commands/users-apply.sh"
# A fleet-wide users file must not abort apply on a host=no box just because
# it names a box-role user somewhere in the fleet: the box role binds where
# VMs live, so on host=no it skips (with a warning) and everything else —
# admins included — still converges.
check "users apply: box role skips on a host=no box" 0 "" \
  grep -q "box role skipped" "$ROOT/commands/users-apply.sh"
# Apply's root-SSH note and close-root's gate must read ONE marker the same
# way, pre-#77 spellings included — a box told "close-root will shut this door"
# by apply and then refused by close-root is the worst of both (#77). Sharing
# the resolver is what guarantees it, so pin the call rather than the message.
# shellcheck disable=SC2016
check "users apply: the root-SSH note resolves through root_door_of" 0 "" \
  grep -qF 'root_door_of "$APPLY_MARKER"' "$ROOT/commands/users-apply.sh"
# ...and it warns, rather than staying silent, on the two markers close-root
# will refuse: a note that only speaks on the happy paths is not a note.
check "users apply: a doorless marker warns that close-root will refuse" 0 "" \
  grep -q "names no root-door policy" "$ROOT/commands/users-apply.sh"
check "users apply: a contradictory marker warns that close-root will refuse" 0 "" \
  grep -q "they disagree" "$ROOT/commands/users-apply.sh"

# --- the box role's host= gate (#58) -----------------------------------------
# The gate is a pure marker->verdict lib function for the same reason
# assert_marker_closes_root is: apply's box arm sits behind the root check, so every
# arm is proven HERE against fixture markers, non-root.
#
# What #58 fixed: the trait used to be consulted only when group incus was
# ABSENT, so a host=no (or marker-less) box that happened to CARRY the group
# handed box-role users a bare `usermod -aG incus` — the socket with no tier,
# which incus-user answers by lazily building an unhardened project under
# whoever opens it. The load-bearing property below is that the verdict comes
# from the marker ALONE and is therefore identical whether or not the group
# exists; the group only decides whether a box that does claim host=yes is
# ready to serve the role.
hostvm_gate() { # hostvm_gate <marker_path>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    assert_marker_hosts_vms "$2"' _ "$ROOT" "$1"
}
HOSTVM_FIX="$(mktemp -d)"
printf 'role=dev-server root-door=closed host=yes join=authkey\n'   > "$HOSTVM_FIX/yes"
printf 'role=workload-server root-door=open host=no join=authkey\n' > "$HOSTVM_FIX/no"
# A marker that predates the host= trait (or was hand-edited): present, but it
# names no host=. Distinct from an ABSENT marker and it must not read as yes.
printf 'role=workload-server root-door=open join=authkey\n'         > "$HOSTVM_FIX/traitless"
check "users apply: host=yes passes the box-role gate" \
  0 "" hostvm_gate "$HOSTVM_FIX/yes"
check "users apply: host=no fails the box-role gate" \
  1 "does not host VMs" hostvm_gate "$HOSTVM_FIX/no"
# The marker-less case gets its own answer rather than falling through to
# either yes or no: rig cannot tell an unbootstrapped box from a repurposed
# one, so it withholds (recoverable by a re-run) and names the repair.
check "users apply: an absent marker fails the box-role gate, names bootstrap" \
  1 "re-run rig bootstrap" hostvm_gate "$HOSTVM_FIX/absent"
check "users apply: a marker with no host= trait fails the gate, names bootstrap" \
  1 "re-run rig bootstrap" hostvm_gate "$HOSTVM_FIX/traitless"
rm -rf "$HOSTVM_FIX"
# The gate must actually be WIRED to the wanted-groups decision, not merely
# exist: this is the line #58 reported, where the box arm used to test group
# presence alone. Pin both operands on that arm — a revert to the INCUS_OK-only
# test must not ship green. It is a gate on whether the ROLE APPLIES, kept
# separate from the mechanism of the add on purpose, so it survives #53 moving
# the add itself into `box grant`.
check "users apply: the incus want is gated on the host= verdict, not just the group" 0 "" \
  grep -qE '\*,box,\*\).*BOX_ROLE_OK.*INCUS_OK.*want incus' "$ROOT/commands/users-apply.sh"
# Marker says no, machine says yes: the skip must NAME the contradiction and
# the one-line repair. The cost of believing the marker is a genuine VM host
# that stops provisioning, and that is only acceptable while it is loud.
check "users apply: a marker/reality mismatch warns and names the repair" 0 "" \
  grep -q "marker and this box's reality disagree" "$ROOT/commands/users-apply.sh"

# --- dropping role box goes through box, not behind its back (#50) -----------
# The 'incus' group is box's: box's setup-host creates it and `box revoke`
# takes it back, warning that supplementary groups are read at LOGIN so a
# session the user already holds keeps the socket until it dies. rig's old bare
# `gpasswd -d` took the group and said nothing, so an operator watching apply
# succeed believed VM access had ended when it had not.
#
# Both removal paths route through one function, so both are covered by the one
# set of assertions below.
check "users apply: both removal paths route incus through drop_incus" 0 "" \
  test "$(grep -c 'drop_incus "\$' "$ROOT/commands/users-apply.sh")" -eq 2
# Convergence removes access, never someone's running machines: '--purge'
# deletes the user's boxes, images and project, and must stay an explicit admin
# act. Asserted by the SHAPE of the one line that invokes box — a bare revoke
# whose effective state is then checked — rather than by grepping the file for
# '--purge', which the rationale comments and --help text mention on purpose,
# to say where it does belong. The captures below prove the same thing at
# runtime, on every path.
# shellcheck disable=SC2016  # the literal source line is the pattern, unexpanded
check "users apply: the box invocation is a bare revoke" 0 "" \
  grep -qF 'if box revoke "$u" && ! in_group "$u" incus; then' \
    "$ROOT/commands/users-apply.sh"

# drop_incus is exercised, not argued about. users-apply.sh EXECUTES when
# sourced (and dies at the root check), so the function is lifted out of the
# real file verbatim — column-0 'drop_incus() {' through column-0 '}' — and
# driven against stub log/warn/in_group and a stub PATH holding only box,
# gpasswd and pgrep. The extraction is asserted first: if that shape ever
# changes the lift comes back empty and every case below fails loudly rather
# than passing vacuously.
DROP_FN="$(sed -n '/^drop_incus() {/,/^}/p' "$ROOT/commands/users-apply.sh")"
# shellcheck disable=SC2016  # $1 is the inner bash -c's positional, deliberately
check "users apply: drop_incus lifts out of the real file whole" 0 "" \
  bash -c '[ -n "$1" ] && printf %s "$1" | grep -q "^}$"' _ "$DROP_FN"

# The driving shell is named by absolute path: PATH below is REPLACED by the
# stub directory (not prefixed) so that 'absent' means absent even on a host
# that really has box installed — which also puts bash itself out of reach of
# a PATH lookup.
BASH_BIN="$(command -v bash)"
# drive_drop <ok|hollow|fail|absent> — run the real drop_incus against stubs.
# 'ok': box revokes and the membership is gone afterwards. 'hollow': box exits
# 0 and leaves the membership standing (the #12 lesson — an exit code is not
# effective state). 'fail': box exits non-zero. 'absent': no box on the host.
drive_drop() {
  local mode="$1" d
  d="$(mktemp -d)"
  mkdir -p "$d/bin"
  : > "$d/member"                     # 'dan is in incus' — removed when taken
  # The stub reports on STDERR: the real call is 'gpasswd -d ... >/dev/null',
  # so a stub that spoke on stdout would be silenced by the code under test and
  # every fallback assertion below would pass vacuously.
  # Each stub restores a real PATH for itself: the caller's PATH is REPLACED by
  # the stub dir (that is what makes 'absent' mean absent), which would other-
  # wise leave the stubs unable to find 'rm'.
  cat > "$d/bin/gpasswd" <<EOF
#!/bin/sh
PATH=/usr/bin:/bin
echo "CALL: gpasswd \$*" >&2
rm -f "$d/member"
EOF
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$d/bin/pgrep"   # dan holds a session
  if [ "$mode" != absent ]; then
    cat > "$d/bin/box" <<EOF
#!/bin/sh
PATH=/usr/bin:/bin
echo "CALL: box \$*"
case "$mode" in
  ok)     rm -f "$d/member" ;;
  hollow) : ;;
  fail)   exit 1 ;;
esac
EOF
  fi
  chmod +x "$d"/bin/*
  # shellcheck disable=SC2016  # $MEMBER/$* resolve inside the driving shell
  MEMBER="$d/member" PATH="$d/bin" "$BASH_BIN" -c '
    set -euo pipefail
    log()  { printf "rig-users: %s\n" "$*"; }
    warn() { printf "rig-users: WARNING: %s\n" "$*" >&2; }
    in_group() { [ -e "$MEMBER" ]; }
    '"$DROP_FN"'
    drop_incus dan' 2>&1
  rm -rf "$d"
}
DROP_OK="$(drive_drop ok)"
DROP_HOLLOW="$(drive_drop hollow)"
DROP_FAIL="$(drive_drop fail)"
DROP_ABSENT="$(drive_drop absent)"
in_out() { printf '%s' "$1" | grep -qF -e "$2"; }   # in_out <captured> <substr>

# The happy path: box takes its own group back, bare, and rig does not reach
# for gpasswd behind it.
check "drop_incus: calls 'box revoke <user>'" 0 "" in_out "$DROP_OK" "CALL: box revoke dan"
# Bare on EVERY path box is reached on, not just the one that works: a retry
# or a fallback must never escalate to the destructive verb.
check "drop_incus: the box call is bare — no --purge" 1 "" in_out "$DROP_OK" "--purge"
check "drop_incus: a hollow success never retries with --purge" 1 "" in_out "$DROP_HOLLOW" "--purge"
check "drop_incus: a failed revoke never retries with --purge" 1 "" in_out "$DROP_FAIL" "--purge"
check "drop_incus: box's success needs no gpasswd" 1 "" in_out "$DROP_OK" "CALL: gpasswd"
check "drop_incus: names box as the one that revoked" 0 "" in_out "$DROP_OK" "via 'box revoke'"

# Effective state, not exit codes: a revoke that returns 0 with the membership
# still standing has not closed the socket, and apply must not report that it
# has.
check "drop_incus: a hollow box success is caught" 0 "" \
  in_out "$DROP_HOLLOW" "did not remove the incus group"
check "drop_incus: a hollow box success falls back to gpasswd" 0 "" \
  in_out "$DROP_HOLLOW" "CALL: gpasswd -d dan incus"
check "drop_incus: a hollow box success never claims box did it" 1 "" \
  in_out "$DROP_HOLLOW" "via 'box revoke'"
check "drop_incus: a failing box revoke falls back to gpasswd" 0 "" \
  in_out "$DROP_FAIL" "CALL: gpasswd -d dan incus"

# No box on the host: rig takes the group itself and carries box's warning,
# because the silence is the bug — an operator must not read "removed" as
# "their sessions are gone too".
check "drop_incus: no box on PATH still removes the group" 0 "" \
  in_out "$DROP_ABSENT" "CALL: gpasswd -d dan incus"
check "drop_incus: the fallback warns that groups are read at login" 0 "" \
  in_out "$DROP_ABSENT" "group membership is read at login"
check "drop_incus: the fallback hands over the remedy" 0 "" \
  in_out "$DROP_ABSENT" "loginctl terminate-user dan"
# Every fallback path carries it, not just the box-less one.
check "drop_incus: the hollow-success fallback warns too" 0 "" \
  in_out "$DROP_HOLLOW" "loginctl terminate-user dan"
check "drop_incus: the failed-revoke fallback warns too" 0 "" \
  in_out "$DROP_FAIL" "loginctl terminate-user dan"
# box only warns when the user has live processes, and rig mirrors that — but
# an absent pgrep means rig cannot tell, and a wrong belief about who reaches
# the daemon costs more than one unnecessary command. Proven by running the
# fallback with a PATH that has no pgrep at all.
NOPGREP_D="$(mktemp -d)"
mkdir -p "$NOPGREP_D/bin"
printf '%s\n' '#!/bin/sh' 'PATH=/usr/bin:/bin' 'echo "CALL: gpasswd $*" >&2' \
  "rm -f $NOPGREP_D/member" > "$NOPGREP_D/bin/gpasswd"
chmod +x "$NOPGREP_D/bin/gpasswd"
: > "$NOPGREP_D/member"
# shellcheck disable=SC2016  # $MEMBER/$* resolve inside the driving shell
DROP_NOPGREP="$(MEMBER="$NOPGREP_D/member" PATH="$NOPGREP_D/bin" "$BASH_BIN" -c '
  set -euo pipefail
  log()  { printf "rig-users: %s\n" "$*"; }
  warn() { printf "rig-users: WARNING: %s\n" "$*" >&2; }
  in_group() { [ -e "$MEMBER" ]; }
  '"$DROP_FN"'
  drop_incus dan' 2>&1)"
check "drop_incus: an absent pgrep warns rather than guessing" 0 "" \
  in_out "$DROP_NOPGREP" "loginctl terminate-user dan"
rm -rf "$NOPGREP_D"

# --- the box role grants the TIER, not just the socket (#49) -----------------
# Group incus is step 1 of the five 'box grant' performs; without the rest the
# user's first 'box new' refuses for want of a box-net profile. Running the
# real thing needs root, an Incus daemon and real accounts, so these assert the
# CALL and its guard rails in the source — the same way every other root-only
# refusal in this harness is pinned.
# The $-refs below are literals we grep FOR in the script — single quotes
# are the point, as in the bootstrap ordering checks above.
# shellcheck disable=SC2016
check "users apply: box role calls 'box grant', not just usermod" 0 "" \
  grep -qE '^[[:space:]]*box grant "\$u"' "$ROOT/commands/users-apply.sh"
# Ordering is the safety property (repo precedent: bootstrap's marker-then-box
# assert): 'box grant' opens with a getent passwd and refuses an unknown user,
# so the call must come AFTER useradd, never before. Defaults fail closed.
useradd_at="$(grep -nE '^[[:space:]]*useradd -m' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
grant_at="$(grep -nE '^[[:space:]]*box grant "\$u"' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
check "users apply: 'box grant' runs after useradd (grant refuses unknown users)" \
  0 "" test "${useradd_at:-999999}" -lt "${grant_at:-0}"
# Failure granularity, both halves. A HOST-level fact — box-role users on a
# host=yes box with no box CLI — dies, like the missing-incus-group die beside
# it. A PER-USER grant failure warns and continues, because one box-role user
# somewhere in the fleet must not stop apply everywhere VMs don't live.
check "users apply: a missing box CLI on host=yes is a die, not a warning" 0 "" \
  grep -qF 'die "a user carries role box and this box hosts VMs (host=yes) but the box CLI is not on PATH' \
  "$ROOT/commands/users-apply.sh"
# shellcheck disable=SC2016
check "users apply: a per-user grant failure warns and continues" 0 "" \
  grep -qF 'warn "box grant $u exited $grant_rc:' "$ROOT/commands/users-apply.sh"
# The grant is host=yes only: a tier converged into a daemon that is not there
# to enforce it is not policy. Read the guard's own block — BOX_GRANT=0 up to
# the line that sets it to 1 — rather than the file at large, so a host=yes
# match borrowed from the die above cannot pass this for free.
# shellcheck disable=SC2016  # $1 resolves inside the inner bash -c
check "users apply: the grant is gated on host=yes" 0 "" \
  bash -c 'awk "/^BOX_GRANT=0\$/,/BOX_GRANT=1 ;;/" "$1" | grep -q "[*]host=yes[*])"' \
  _ "$ROOT/commands/users-apply.sh"
# The incus-admin case is blocked on heavy-duty/box#99: grant refuses those
# members today, and rig must NOT turn that refusal into a failed apply. The
# branch names the blocker so whoever reads the warning can find the fix.
# shellcheck disable=SC2016
check "users apply: an incus-admin grant refusal is warned, not fatal" 0 "" \
  grep -q 'elif in_group "$u" incus-admin; then' "$ROOT/commands/users-apply.sh"
check "users apply: the incus-admin warning cites the box-side blocker" 0 "" \
  grep -q "heavy-duty/box#99" "$ROOT/commands/users-apply.sh"
# The group ADD is deferred to grant so a failed grant can take the socket back
# with it (grant only rolls back a membership THAT RUN added). But incus must
# stay in the WANTED set, or the exact-convergence loop's other arm would strip
# a box-role user's socket on the very run that granted it — assert both, since
# either alone is a bug.
# shellcheck disable=SC2016
check "users apply: the incus group add is deferred to 'box grant'" 0 "" \
  grep -qF 'if [ "$g" = incus ] && [ "$BOX_GRANT" -eq 1 ]; then continue; fi' \
  "$ROOT/commands/users-apply.sh"
# The wanted-set arm gained #58's BOX_ROLE_OK gate on rebase, and the two
# conditions answer different questions: BOX_ROLE_OK is "does the box role
# apply on this box at all" (the marker's call), INCUS_OK is "is the group
# there to converge". Both must hold, and `incus` must still ENTER the wanted
# set when they do — otherwise the exact-convergence else-arm below would
# strip a box-role user's socket on the very run that granted it, which is
# the hazard this PR exists to remove. Pinned as the composed line so a
# regression in either operand fails here.
# shellcheck disable=SC2016
check "users apply: role box still puts incus in the wanted set" 0 "" \
  grep -qF 'case ",$roles," in *,box,*) if [ "$BOX_ROLE_OK" -eq 1 ] && [ "$INCUS_OK" -eq 1 ]; then want="$want incus"; fi ;; esac' \
  "$ROOT/commands/users-apply.sh"
# The deferral must be an ADD-side skip only. Landing it on the removal arm
# would leave a de-roled user's socket open forever, so prove the guard sits
# above the usermod -aG and below the wanted-set case, not in the else branch.
# shellcheck disable=SC2016
defer_at="$(grep -nF 'if [ "$g" = incus ] && [ "$BOX_GRANT" -eq 1 ]; then continue; fi' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
strip_at="$(grep -nE '^[[:space:]]*gpasswd -d "\$u" "\$g"' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
check "users apply: the deferral sits on the add arm, not the removal arm" \
  0 "" test "${defer_at:-999999}" -lt "${strip_at:-0}"
# rig still never installs Incus (the #12/#25 design law, asserted for
# bootstrap above): calling box's grant is invocation, not installation.
check "users apply: never apt-installs incus (box owns the daemon)" 1 "" \
  grep -nE 'apt-get install.* incus' "$ROOT/commands/users-apply.sh"

# --- users close-root: the human-class root-door shutter ---------------------
check "users close-root: --help exits 0"       0 "usage:"       "$ROOT/commands/users-close-root.sh" --help
check "users close-root: unknown flag exits 2" 2 "unknown flag" "$ROOT/commands/users-close-root.sh" --nope
# The whole command rests on first-wins + lexical include order: '-' (0x2D)
# sorts before '.' (0x2E), so 00-rig-users.conf is read before bootstrap's
# 00-rig.conf and its PermitRootLogin wins. Assert the actual comparison the
# glob makes, so a renamed drop-in cannot silently lose the fight.
check "users close-root: drop-in name sorts before bootstrap's" 0 "" \
  bash -c '[ "00-rig-users.conf" \< "00-rig.conf" ]'
check "users close-root: drop-in name is the load-bearing one" 0 "" \
  grep -q "00-rig-users.conf" "$ROOT/commands/users-close-root.sh"
# Validate-then-apply: `sshd -t` on the merged config must precede the restart —
# on a box whose only door is SSH (exactly what this box is about to become),
# bouncing the daemon into a config it refuses to parse leaves no way back in.
# Match the call, not the word (repo precedent: the repo-guard ordering check);
# defaults fail closed.
sshdt_at="$(grep -nE '^[[:space:]]*if ! sshd_config_ok' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
restart_at="$(grep -n 'systemctl restart ssh' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
check "users close-root: sshd -t precedes the ssh restart" \
  0 "" test "${sshdt_at:-999999}" -lt "${restart_at:-0}"
# Convergence is a claim about the DOOR, not the file. Matching bytes can hide
# an earlier-sorting override (first-wins) or a daemon that died between
# install and restart and never read the file — so the no-op message may only
# be spoken after the effective-config assertion (`sshd -T`), and the no-op
# branch may only be TAKEN when the daemon provably started after the last
# change to sshd's config inputs. Pin both: the assert-before-claim ordering,
# and the daemon-start-vs-config-mtime proof's presence.
efft_at="$(grep -n 'sshd -T' "$ROOT/commands/users-close-root.sh" | grep -v '^[0-9]*:#' | head -n1 | cut -d: -f1)"
noop_at="$(grep -n 'nothing to do' "$ROOT/commands/users-close-root.sh" | tail -n1 | cut -d: -f1)"
check "users close-root: no-op claim sits after the effective-config assert" \
  0 "" test "${efft_at:-999999}" -lt "${noop_at:-0}"
check "users close-root: no-op needs a daemon start newer than the config" 0 "" \
  grep -q "ExecMainStartTimestamp" "$ROOT/commands/users-close-root.sh"
# The admin-door gate must check the StrictModes SHAPE, not file existence: a
# non-empty authorized_keys behind group/world-writable perms is a key sshd
# rejects — closing root behind it welds the only door shut. The full gate
# needs root + real accounts, so grep the load-bearing check's wording.
check "users close-root: gate checks the StrictModes shape" 0 "" \
  grep -q "group/world-writable" "$ROOT/commands/users-close-root.sh"
# The reachability proofs (#17): the shape checks prove the door SHOULD open;
# these prove what can be proven from inside — NOPASSWD sudo actually answers
# (`runuser ... sudo -n true`) and sshd's per-user EFFECTIVE config accepts
# the login (`sshd -T -C user=...`). Both need root, real accounts, and a
# live sshd, so grep the calls — and pin their ordering BEFORE the drop-in
# install, because reachability proven after the door shut is no proof at
# all. Match the calls, not the words (comments mention neither literal);
# defaults fail closed.
# The $a/$TMP/$DROPIN below are LITERALS we grep for in the script — single
# quotes are the point, as in the db and box-install checks.
# shellcheck disable=SC2016
check "users close-root: gate proves NOPASSWD sudo answers" 0 "" \
  grep -qF -- 'runuser -u "$a" -- sudo -n true' "$ROOT/commands/users-close-root.sh"
check "users close-root: gate resolves sshd's per-user config" 0 "" \
  grep -qF -- 'sshd -T -C "user=' "$ROOT/commands/users-close-root.sh"
# shellcheck disable=SC2016
sudon_at="$(grep -nF -- 'runuser -u "$a" -- sudo -n true' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
pert_at="$(grep -nF -- 'sshd -T -C "user=' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
dropin_at="$(grep -nF 'install -m 0644 "$TMP" "$DROPIN"' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
check "users close-root: sudo -n proof precedes the drop-in install" \
  0 "" test "${sudon_at:-999999}" -lt "${dropin_at:-0}"
check "users close-root: per-user sshd resolve precedes the drop-in install" \
  0 "" test "${pert_at:-999999}" -lt "${dropin_at:-0}"
# runuser may be absent off-Debian; the gate must skip that one proof loudly,
# never die on a missing prover. Grep the graceful branch.
check "users close-root: a missing runuser skips the sudo proof, loudly" 0 "" \
  grep -q "runuser not found" "$ROOT/commands/users-close-root.sh"
# DenyUsers judged fail-closed through the lib's pure deny_verdict — sshd
# accepts patterns and USER@HOST forms, and 'DenyUsers dan*' REALLY denies
# admin 'dan', so a token the check cannot prove irrelevant must flag, never
# pass (the review's regression: a wildcard denial). Empty output is the only
# pass; every hit names its reason.
deny_v() { # deny_v <user> <token...>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"; shift
    deny_verdict "$@"' _ "$ROOT" "$@"
}
check "users close-root: deny_verdict flags a literal hit" \
  0 "names this user" deny_v admin root admin
check "users close-root: deny_verdict fails closed on a wildcard (dan* vs dan)" \
  0 "pattern entry 'dan*'" deny_v dan "dan*"
check "users close-root: deny_verdict fails closed on '?' patterns" \
  0 "pattern entry" deny_v admin "admi?"
check "users close-root: deny_verdict fails closed on USER@HOST forms" \
  0 "host-qualified" deny_v admin "admin@10.0.0.1"
deny_pass() { [ -z "$(deny_v "$@")" ]; } # empty verdict IS the pass
check "users close-root: deny_verdict passes provably-irrelevant literals" \
  0 "" deny_pass admin root git backup
# The group directives, same discipline, judged against the candidate's ACTUAL
# membership (the review's regressions: an unmet AllowGroups, a DenyGroups
# naming a group they hold). First arg is the id -Gn word list.
groups_v() { # groups_v <fn> <groups> <token...>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"; shift
    "$@"' _ "$ROOT" "$@"
}
groups_pass() { [ -z "$(groups_v "$@")" ]; }
check "users close-root: DenyGroups naming a held group flags" \
  0 "a group this user is in" groups_v group_deny_verdict "dan sudo rig-admin" backup sudo
check "users close-root: DenyGroups fails closed on patterns" \
  0 "pattern entry 'rig-*'" groups_v group_deny_verdict "dan rig-admin" "rig-*"
check "users close-root: DenyGroups passes provably-irrelevant literals" \
  0 "" groups_pass group_deny_verdict "dan rig-admin" docker backup
check "users close-root: an unmet AllowGroups flags (fail closed)" \
  0 "no entry literally names a group this user is in" groups_v group_allow_verdict "dan rig-admin" sudo
check "users close-root: AllowGroups pattern is no proof (fail closed)" \
  0 "no entry literally names" groups_v group_allow_verdict "dan rig-admin" "rig-*"
check "users close-root: a literally-named held group passes AllowGroups" \
  0 "" groups_pass group_allow_verdict "dan rig-admin" sudo rig-admin
# ...and the shipped gate consults both, against real membership.
# shellcheck disable=SC2016
check "users close-root: the gate consults the group verdicts" 0 "" \
  grep -qE '^[[:space:]]*denyg_reason="\$\(group_deny_verdict ' "$ROOT/commands/users-close-root.sh"
# shellcheck disable=SC2016
check "users close-root: the gate resolves real membership (id -Gn)" 0 "" \
  grep -qF -- 'id -Gn -- "$a"' "$ROOT/commands/users-close-root.sh"
# ...and the shipped gate must actually consult it (call, not comment).
# shellcheck disable=SC2016
check "users close-root: the gate consults deny_verdict" 0 "" \
  grep -qE '^[[:space:]]*deny_reason="\$\(deny_verdict ' "$ROOT/commands/users-close-root.sh"
# Marker-gate refusals through the sourced lib against fixture markers: the CLI
# path sits behind the root check, so the gate is a pure lib function on
# purpose (repo precedent: parse_users_file, assert_runner_repo). The command
# reads the marker path from RIG_ROLE_MARKER for the same reason — so the gate
# stays pointable at fixtures.
marker_gate() { # marker_gate <marker_path>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    assert_marker_closes_root "$2"' _ "$ROOT" "$1"
}
MARKER_DIR="$(mktemp -d)"
printf 'role=workload-server root-door=open host=no join=authkey\n'   > "$MARKER_DIR/open"
printf 'role=dev-server root-door=closed host=yes join=authkey\n'     > "$MARKER_DIR/closed"
check "users close-root: absent marker refuses, names bootstrap as the repair" \
  1 "no /etc/rig/role marker" marker_gate "$MARKER_DIR/absent"
check "users close-root: root-door=open refuses, names the control plane" \
  1 "control plane" marker_gate "$MARKER_DIR/open"
# #17's original table let the runner ROLE close root; the trait model
# supersedes it — runner is root-door=open, an automation identity, and the
# refusal must SAY so or the divergence reads as a bug to anyone holding the
# old table.
check "users close-root: the open-door refusal owns the runner row (#17)" \
  1 "runner included" marker_gate "$MARKER_DIR/open"
check "users close-root: root-door=closed passes the gate" \
  0 "" marker_gate "$MARKER_DIR/closed"

# --- the pre-#77 vocabulary, on live markers (#77) ---------------------------
# THIS is the block that makes #77 safe to ship, and it is not a formality.
# Unlike #76's role rename, the root-door trait is written into /etc/rig/role
# and read BACK by this gate, so every box bootstrapped before the rename
# carries `class=human|server` and carries it until someone re-bootstraps it —
# which, for a fleet, is never. A gate that stopped understanding that spelling
# would fail in both directions and both are incidents: `class=human` boxes
# (whose whole point is that root closes) would lose the ability to close it,
# and `class=server` boxes would... also refuse, but for the wrong reason,
# which is luck rather than design and would evaporate the moment the fallthrough
# arm changed.
#
# So the fixtures below stay DELIBERATELY at the retired spelling, byte for
# byte as a real pre-#77 box's marker reads — the same reason #76's
# `pre-rename-cp` fixture keeps `role=control-plane`. Do not "modernize" them:
# updating these fixtures to the new vocabulary would delete the only evidence
# that the compat read works, and the suite would stay green while the field
# broke. The pairs assert the OLD spelling produces the SAME verdict as its new
# equivalent above, refusal text included.
printf 'role=workload-server class=server host=no join=authkey\n'     > "$MARKER_DIR/pre77-server"
printf 'role=dev-server class=human host=yes join=authkey\n'          > "$MARKER_DIR/pre77-human"
check "users close-root: a PRE-#77 'class=human' marker still passes the gate" \
  0 "" marker_gate "$MARKER_DIR/pre77-human"
check "users close-root: a PRE-#77 'class=server' marker still REFUSES" \
  1 "control plane" marker_gate "$MARKER_DIR/pre77-server"
# The refusal an old box gets must be the CURRENT one, naming the current flag:
# an operator repairing a pre-#77 box is repairing it with today's rig, and
# being told to pass a flag that no longer exists is a dead end.
check "users close-root: the PRE-#77 refusal names today's flag, not --class" \
  1 "root-door closed" marker_gate "$MARKER_DIR/pre77-server"

# A marker naming NEITHER vocabulary refuses — unchanged from before #77, and
# distinct from an absent marker: the file exists and simply makes no claim
# about the door, which cannot authorize shutting one.
printf 'role=workload-server host=no join=authkey\n'                  > "$MARKER_DIR/doorless"
check "users close-root: a marker naming no door policy refuses" \
  1 "names no root-door policy" marker_gate "$MARKER_DIR/doorless"
# A marker naming a root-door= value outside the value set is doorless too —
# fail closed rather than guessing which door 'potato' means.
printf 'role=custom root-door=potato host=no join=login\n'            > "$MARKER_DIR/bogus"
check "users close-root: an unreadable root-door value refuses (fail closed)" \
  1 "names no root-door policy" marker_gate "$MARKER_DIR/bogus"

# BOTH vocabularies on one marker. Agreement is just the same claim twice and
# resolves normally; DISAGREEMENT is a hand-edited marker making two equally
# authored claims about a root door, and rig refuses to pick a winner — the
# fail-closed arm, since the alternative is guessing on the one field that
# decides whether a door welds shut. Both orders are checked so the verdict
# cannot depend on which field the editor happened to type first.
printf 'role=dev-server root-door=closed class=human host=yes join=authkey\n' > "$MARKER_DIR/both-agree"
check "users close-root: both vocabularies agreeing resolves normally" \
  0 "" marker_gate "$MARKER_DIR/both-agree"
printf 'role=custom root-door=closed class=server host=no join=login\n'  > "$MARKER_DIR/both-fight-a"
printf 'role=custom class=human root-door=open host=no join=login\n'     > "$MARKER_DIR/both-fight-b"
check "users close-root: contradictory vocabularies refuse (new-first)" \
  1 "will not pick a winner" marker_gate "$MARKER_DIR/both-fight-a"
check "users close-root: contradictory vocabularies refuse (old-first)" \
  1 "will not pick a winner" marker_gate "$MARKER_DIR/both-fight-b"
rm -rf "$MARKER_DIR"

# root_door_of is the ONE reader of this trait — close-root's gate, apply's
# note and bootstrap-tenant's machine-marker detector all resolve through it,
# so the compat read cannot drift between them. Pin the resolver directly,
# text->text, the way deny_verdict and group_allow_verdict are pinned.
door_of() { # door_of <marker line>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    printf "[%s]" "$(root_door_of "$2")"' _ "$ROOT" "$1"
}
check "root_door_of: reads the current vocabulary" 0 "[closed]" \
  door_of 'role=dev-server root-door=closed host=yes join=authkey'
check "root_door_of: reads the pre-#77 class=human as closed" 0 "[closed]" \
  door_of 'role=dev-server class=human host=yes join=authkey'
check "root_door_of: reads the pre-#77 class=server as open" 0 "[open]" \
  door_of 'role=workload-server class=server host=no join=authkey'
check "root_door_of: a tenant marker names no door at all" 0 "[]" \
  door_of 'role=claude-box tenant=yes host=no'
check "root_door_of: disagreement is a conflict, not a coin flip" 0 "[conflict]" \
  door_of 'role=custom root-door=open class=human host=no join=login'
# FIELD-ANCHORED, not substring (found in review on #77). A value that EXTENDS
# a real one must resolve EMPTY and fail closed, exactly as the function's
# header promises — before anchoring, `closedish` read as `closed` and PERMITTED
# close-root, the one arm that authorizes an irreversible act. Both vocabularies
# are checked: the compat arm had the identical hole, and a fix that anchored
# only the current spelling would leave every pre-#77 box exposed to it.
check "root_door_of: a value EXTENDING the current spelling resolves empty" 0 "[]" \
  door_of 'role=x root-door=closedish host=no'
check "root_door_of: a value extending the pre-#77 spelling resolves empty too" 0 "[]" \
  door_of 'role=x class=humanoid host=no'
check "root_door_of: a value PREFIXED by junk does not match either" 0 "[]" \
  door_of 'role=x notroot-door=closed host=no'
# ...and the gate itself must refuse on those, not merely resolve empty: the
# resolver returning "" is only safe because every consumer treats it as a
# refusal, so the end-to-end behaviour is what gets pinned.
DOOR_FIX="$(mktemp -d)"
printf 'role=x root-door=closedish host=no\n' > "$DOOR_FIX/bogus"
# shellcheck disable=SC2016  # $1/$2 are the inner shell's positionals, not ours
check "close-root: refuses a marker whose door value merely LOOKS closed" 1 "names no root-door policy" \
  bash -c '. "$1/commands/lib/users-config.sh"; assert_marker_closes_root "$2"' _ "$ROOT" "$DOOR_FIX/bogus"
# Whitespace normalisation: a hand-edit using tabs is still a real marker and
# must read the same, or anchoring would trade one silent misread for another.
check "root_door_of: tab-separated fields read the same as space-separated" 0 "[closed]" \
  door_of "$(printf 'role=x\troot-door=closed\thost=no')"
rm -rf "$DOOR_FIX"
if [ "$(id -u)" -ne 0 ]; then
  check "users close-root: refuses non-root" 1 "must run as root" "$ROOT/commands/users-close-root.sh"
else
  echo "skip: users close-root non-root refusal (running as root)"
fi
# Bootstrap must read the closed door as hardened, not broken: `no` is the
# post-close-root state, strictly harder than what bootstrap installs. Byte-grep
# the widened assertion so a revert cannot ship green. The hardening block
# lives in lib/sshd.sh since #31 — ONE converger shared by the machine roles
# and the staging-box tenant — so the greps pin the lib, and a call-site grep pins
# that bootstrap actually runs it (a function nobody calls is not hardening).
check "sshd lib: permitrootlogin assertion accepts the closed state" 0 "" \
  grep -qF "permitrootlogin (no|prohibit-password|without-password)" "$ROOT/commands/lib/sshd.sh"
# ...but only for root-door=closed. On root-door=open a closed root door is a
# BROKEN box — root SSH is the control plane's automation door — and the usual
# cause is a 00-rig-users.conf left over from a former closed-door life. The refusal
# must name that drop-in or the operator greps sshd configs blind; the path
# needs root + a doctored sshd, so grep the die message (repo precedent above).
check "sshd lib: root-door=open refusal names the stale close-root drop-in" 0 "" \
  grep -q "leftover /etc/ssh/sshd_config.d/00-rig-users.conf" "$ROOT/commands/lib/sshd.sh"
# Validate-then-apply survived the extraction: sshd -t on the merged config
# must still precede the restart (same idiom as the close-root ordering check).
libt_at="$(grep -nE '^[[:space:]]*if ! sshd_config_ok' "$ROOT/commands/lib/sshd.sh" | head -n1 | cut -d: -f1)"
librestart_at="$(grep -nE '^[[:space:]]*systemctl restart ssh$' "$ROOT/commands/lib/sshd.sh" | head -n1 | cut -d: -f1)"
check "sshd lib: sshd -t precedes the ssh restart" \
  0 "" test "${libt_at:-999999}" -lt "${librestart_at:-0}"
# `sshd -t` answers TWO questions through ONE exit code: is the merged config
# parseable, and is the privilege-separation directory there. /run is a tmpfs
# and /run/sshd is ssh.service's RuntimeDirectory — systemd removes it when
# that unit stops — so it is legitimately absent under socket activation
# (ssh.socket, the default on current Debian/Ubuntu) on a box whose SSH door is
# serving connections normally. Reading that as "the config is bad" aborted
# bootstrap with a verdict sshd never reached, and sent the operator to audit
# /etc/ssh files that were never broken (#92). The classifier is pure and
# sourceable so the distinction is proven here, non-root and without a live
# sshd (repo precedent: parse_users_file, deny_verdict).
privsep_gap() { # privsep_gap <status> <stderr-text>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/sshd.sh"
    sshd_privsep_gap "$2" "$3"' _ "$ROOT" "$1" "$2"
}
check "sshd lib: a missing privsep dir is not a config verdict" 0 "" \
  privsep_gap 1 "Missing privilege separation directory: /run/sshd"
check "sshd lib: a genuine parse refusal stays a config verdict" 1 "" \
  privsep_gap 1 "/etc/ssh/sshd_config.d/50-cloud-init.conf: line 3: Bad configuration option: frobnicate"
# The STATUS is the verdict; the text only classifies a failure. A passing
# sshd -t is never diverted, whatever its output happens to say — otherwise a
# box could be sent down the repair path with nothing wrong with it.
check "sshd lib: a passing sshd -t is never read as a privsep gap" 1 "" \
  privsep_gap 0 "Missing privilege separation directory: /run/sshd"
# Surfacing sshd's own words is the substance of #92: the old message asserted a
# cause and then discarded, via 2>/dev/null, the one line that named the real
# one. Both call sites make the claim, so both are pinned.
# shellcheck disable=SC2016  # the literal source line is the pattern, unexpanded
check "sshd lib: the refusal quotes sshd's own stderr" 0 "" \
  grep -qF 'daemon untouched: $sshd_err' "$ROOT/commands/lib/sshd.sh"
# shellcheck disable=SC2016
check "users close-root: the refusal quotes sshd's own stderr" 0 "" \
  grep -qF 'daemon untouched: $sshd_err' "$ROOT/commands/users-close-root.sh"
# ...and the gap is REPAIRED, not merely diagnosed: a message the operator must
# act on by hand is still a blocked bootstrap.
check "sshd lib: the privsep gap is repaired before the retest" 0 "" \
  grep -qF 'install -d -m 0755 /run/sshd' "$ROOT/commands/lib/sshd.sh"
# close-root does NOT carry its own copy of that repair — it reaches it through
# the shared lib. #31 extracted ONE sshd converger precisely so a judgement
# cannot drift between the two commands, and #92 is what drift costs: the same
# flawed three lines sat in both files and had to be fixed twice. Pin the
# sharing, not a duplicate: the source line and the call.
# shellcheck disable=SC2016
check "users close-root: validates through the shared sshd lib" 0 "" \
  grep -qE '^\. "\$HERE/lib/sshd\.sh"$' "$ROOT/commands/users-close-root.sh"
check "users close-root: no second copy of the privsep repair" 1 "" \
  grep -qF 'install -d -m 0755 /run/sshd' "$ROOT/commands/users-close-root.sh"
# shellcheck disable=SC2016
check "bootstrap: hardening runs through the shared lib" 0 "" \
  grep -qE '^harden_sshd "\$ROOT_DOOR"$' "$ROOT/commands/bootstrap.sh"

# The dump script ships to control-plane boxes as an embedded heredoc. A syntax
# error in it would be invisible here and would first surface at 04:00 on a live
# control plane. Extract it and syntax-check what actually gets written.
DUMP_TMP="$(mktemp)"
sed -n "/<<'DUMP_SCRIPT'/,/^DUMP_SCRIPT\$/p" "$ROOT/commands/coolify-backup-install.sh" \
  | sed '1d;$d' > "$DUMP_TMP"
check "embedded dump script extracted (guards the sed above)" 0 "" grep -q "pg_dump" "$DUMP_TMP"
check "embedded dump script is valid bash"    0 ""        bash -n "$DUMP_TMP"
check "embedded dump script rejects a bare bucket name" 1 "must be an s3:// URI" \
  env AGE_RECIPIENT=age1x S3_BUCKET=my-bucket S3_ENDPOINT=https://s3.example.com bash "$DUMP_TMP"
check "embedded dump script rejects a schemeless endpoint" 1 "needs a scheme" \
  env AGE_RECIPIENT=age1x S3_BUCKET=s3://b/k S3_ENDPOINT=s3.example.com bash "$DUMP_TMP"
rm -f "$DUMP_TMP"

# Regression: /etc/os-release defines VERSION (e.g. "13 (trixie)" on Debian);
# sourcing it in the main shell clobbers a script's $VERSION and splices the
# OS string into download URLs. It must only ever be sourced in a subshell.
check "no main-shell os-release sourcing" 1 "" \
  grep -rnE '^[[:space:]]*\.[[:space:]]+/etc/os-release' "$ROOT/commands"

# ---------------------------------------------------------------------------
# /etc/rig/manifest — provenance (#61)
#
# The writer is a pure text→text renderer behind a cmp-guard, for the same
# reason assert_marker_human and parse_users_file are pure: the write itself
# sits behind bootstrap's root check, so every RULE is proven here, non-root,
# against fixtures — and the rules are the whole feature.
# ---------------------------------------------------------------------------
# Every helper sources the lib in a SUBSHELL, so the harness's own $PASS/$FAIL
# and the lib's globals never meet (repo precedent: the bash -c gates above,
# same isolation, one less quoting layer).
render() {   # render <path> <version> <now>
  ( set -euo pipefail
    . "$ROOT/commands/lib/manifest.sh"
    manifest_render "$1" "$2" "$3" )
}
stamp() {    # stamp <path> <version> — the side-effecting writer
  ( set -euo pipefail
    . "$ROOT/commands/lib/manifest.sh"
    RIG_MANIFEST="$1" manifest_stamp "$2" )
}
running_version() {   # running_version <rig tree root>
  ( set -euo pipefail
    . "$ROOT/commands/lib/manifest.sh"
    manifest_running_version "$1" )
}
mode_of()  { stat -c %a "$1"; }
mtime_of() { stat -c %Y "$1"; }
text_is()  { [ "$(cat "$1")" = "$2" ]; }
MF="$(mktemp -d)"

# -- the shape on a virgin machine ------------------------------------------
check "manifest: a fresh render carries schema=1" 0 "schema=1" \
  render "$MF/absent" 0.4.0 2026-07-19T14:24:51Z
check "manifest: a fresh render pins birth to the running version" 0 "bootstrapped_by=0.4.0" \
  render "$MF/absent" 0.4.0 2026-07-19T14:24:51Z
check "manifest: a fresh render stamps birth with now" 0 "bootstrapped_at=2026-07-19T14:24:51Z" \
  render "$MF/absent" 0.4.0 2026-07-19T14:24:51Z
# Both pairs equal on a fresh machine: mild redundancy, in exchange for a file
# no reader ever has to infer a missing field from.
check "manifest: a fresh render writes latest equal to birth" 0 "converged_by=0.4.0" \
  render "$MF/absent" 0.4.0 2026-07-19T14:24:51Z
check "manifest: a fresh render stamps latest with now" 0 "converged_at=2026-07-19T14:24:51Z" \
  render "$MF/absent" 0.4.0 2026-07-19T14:24:51Z
# key=value, one per line, nothing else — the shape a machine with no jq and no
# YAML parser can read with `read`. Five lines, no quoting, no nesting.
render_is_flat_kv() {   # render_is_flat_kv <path> <version>
  local out
  out="$(render "$1" "$2" 2026-07-19T14:24:51Z)" || return 1
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 5 ] || return 1
  ! printf '%s\n' "$out" | grep -qvE '^[a-z_]+=[^ ]*$'
}
check "manifest: the render is bare key=value, one per line" 0 "" \
  render_is_flat_kv "$MF/absent" 0.4.0

# -- THE CRUX: convergence ---------------------------------------------------
# bootstrap.sh:3 promises "a second run changes nothing", enforced by a
# cmp-guard before every file install. A naive `converged_at=$(now)` would
# break that promise on every single re-run — the file would differ by a
# timestamp, the guard would fire, and rig would report a change it did not
# make. Rules 1 and 2 make the rendered content a function of (existing file,
# running version) alone.
#
# Proven the strong way: render the SAME fixture twice with two clock readings
# a year apart and diff. Byte-identical output means the clock cannot reach the
# file at all — a stronger claim than re-running the writer quickly enough that
# the two stamps happen to match by luck.
clock_cannot_reach() {   # clock_cannot_reach <path> <version>
  diff <(render "$1" "$2" 2027-01-01T00:00:00Z) <(render "$1" "$2" 2028-06-06T06:06:06Z)
}
reproduces_itself() {    # reproduces_itself <path> <version>
  diff <(render "$1" "$2" 2029-09-09T09:09:09Z) "$1"
}
BORN="$MF/born"
render "$MF/absent" 0.4.0 2026-07-19T14:24:51Z > "$BORN"
check "manifest: re-render by the SAME rig is byte-identical across a year of clock" 0 "" \
  clock_cannot_reach "$BORN" 0.4.0
check "manifest: re-render by the same rig equals the file it read" 0 "" \
  reproduces_itself "$BORN" 0.4.0
# The same property through the WRITER, which is what bootstrap actually calls:
# a first stamp writes (exit 0), a second by the same rig reports the file
# already current (exit 1) and touches nothing.
STAMPED="$MF/stamped"
check "manifest: the first stamp writes the file" 0 "" stamp "$STAMPED" 0.4.0
check "manifest: the file landed 0644 — an audit record nobody can read is not one" \
  0 "644" mode_of "$STAMPED"
BEFORE="$(cat "$STAMPED")"
check "manifest: a second stamp by the same rig reports already-current" 1 "" stamp "$STAMPED" 0.4.0
check "manifest: a second stamp by the same rig changed no byte" 0 "" \
  text_is "$STAMPED" "$BEFORE"

# -- a DIFFERENT rig: a real diff, and only where it belongs ----------------
# The cmp-guard firing here is CORRECT, not spurious. It was only ever the
# clock that was the fake change, never the version.
check "manifest: a re-converge by a newer rig moves converged_by" 0 "converged_by=0.6.0" \
  render "$BORN" 0.6.0 2026-08-02T09:11:03Z
check "manifest: a re-converge by a newer rig moves converged_at" 0 "converged_at=2026-08-02T09:11:03Z" \
  render "$BORN" 0.6.0 2026-08-02T09:11:03Z
# Rule 1, the load-bearing half: birth is FIRST-WRITE-WINS. bootstrapped_by
# must survive every later convergence — "what built this box" is unanswerable
# by any other means once the run is over.
check "manifest: a re-converge leaves the birth version pinned" 0 "bootstrapped_by=0.4.0" \
  render "$BORN" 0.6.0 2026-08-02T09:11:03Z
check "manifest: a re-converge leaves the birth stamp pinned" 0 "bootstrapped_at=2026-07-19T14:24:51Z" \
  render "$BORN" 0.6.0 2026-08-02T09:11:03Z
check "manifest: the writer sees a version change as a real change" 0 "" stamp "$STAMPED" 0.6.0
check "manifest: and settles again on the new version" 1 "" stamp "$STAMPED" 0.6.0

# -- a DOWNGRADE is a change too --------------------------------------------
# converged_by is "the rig that last converged this", not "the highest one ever
# seen". Rolling back with `rig use` and re-converging must be recorded, or the
# file would name a version that is no longer what runs here.
check "manifest: re-converging with an OLDER rig is recorded, not ignored" 0 "converged_by=0.1.0" \
  render "$BORN" 0.1.0 2026-09-09T09:09:09Z

# -- forward compatibility: unknown keys survive the rewrite ----------------
# The schema promises readers ignore keys they do not know. That promise is
# worthless if the WRITER eats them: a manifest touched by a newer rig, or
# carrying a later command's own provenance line, must come back whole.
FOREIGN="$MF/foreign"
{ cat "$BORN"; printf 'runner_installed_at=2026-07-19T16:10:00Z\n'; printf 'schema_future_key=x\n'; } > "$FOREIGN"
check "manifest: a later command's provenance line survives a rewrite" 0 "runner_installed_at=2026-07-19T16:10:00Z" \
  render "$FOREIGN" 0.6.0 2026-08-02T09:11:03Z
check "manifest: a key from a newer schema survives a rewrite" 0 "schema_future_key=x" \
  render "$FOREIGN" 0.6.0 2026-08-02T09:11:03Z
# And preserving them must not cost convergence: a file carrying foreign keys is
# still byte-stable under a same-version re-render.
check "manifest: foreign keys do not break convergence" 0 "" \
  reproduces_itself "$FOREIGN" 0.4.0

# -- damaged files: repair once, then settle --------------------------------
# A truncated or hand-edited manifest must converge back to a whole one and
# then STAY PUT — a repair that re-fires on every run is a clock by another
# name, and would break convergence exactly where it is hardest to notice.
printf 'bootstrapped_at=2020-01-01T00:00:00Z\n' > "$MF/noby"
check "manifest: a birth stamp with no birth version records unknown, never today's" \
  0 "bootstrapped_by=unknown" render "$MF/noby" 0.4.0 2026-07-19T14:24:51Z
check "manifest: ...and still keeps the birth stamp it does have" \
  0 "bootstrapped_at=2020-01-01T00:00:00Z" render "$MF/noby" 0.4.0 2026-07-19T14:24:51Z
printf 'schema=1\nbootstrapped_by=0.4.0\nbootstrapped_at=2020-01-01T00:00:00Z\nconverged_by=0.4.0\n' > "$MF/noat"
REPAIRED="$MF/repaired"
render "$MF/noat" 0.4.0 2026-07-19T14:24:51Z > "$REPAIRED"
check "manifest: a converged_by with no converged_at is repaired once" 0 "converged_at=2026-07-19T14:24:51Z" \
  cat "$REPAIRED"
check "manifest: the repair settles — it does not re-fire on the next run" 0 "" \
  reproduces_itself "$REPAIRED" 0.4.0

# -- a final line with NO trailing newline ----------------------------------
# A bare `while read` stops at EOF without ever handing over a populated
# partial line, so the last record of an unterminated file reads as ABSENT.
# That is not a cosmetic parse miss here: absent is exactly the input both
# rules key off, so the file's last line is the one least able to survive it.
# A hand-edit with an editor that adds no final newline, or a truncated write,
# is enough to produce one. The reader idiom is the repo's own —
# lib/users-config.sh:49 reads `|| [ -n "$line" ]` for the same reason.
NONL="$MF/nonl-owned"
printf 'schema=1\nbootstrapped_by=0.4.0\nbootstrapped_at=2020-01-01T00:00:00Z\nconverged_by=0.4.0\nconverged_at=2020-01-01T00:00:00Z' > "$NONL"
# The crux assertion, applied to the case that broke it: with converged_at
# unreadable, Rule 2 saw an empty at-stamp and re-fired the "one-time" repair
# on EVERY run, so the clock reached the file after all.
check "manifest: an unterminated final line does not let the clock back in" 0 "" \
  clock_cannot_reach "$NONL" 0.4.0
check "manifest: an unterminated converged_at is read, not re-stamped" 0 "converged_at=2020-01-01T00:00:00Z" \
  render "$NONL" 0.4.0 2026-07-19T14:24:51Z
# Rule 1 on the field that can never be reconstructed: a file truncated mid-way
# ends AT bootstrapped_at, so the unterminated line is the birth stamp itself —
# and regenerating it is the one loss no later run can undo.
printf 'schema=1\nbootstrapped_by=0.4.0\nbootstrapped_at=2020-01-01T00:00:00Z' > "$MF/nonl-birth"
check "manifest: an unterminated birth stamp stays pinned, not reborn today" 0 "bootstrapped_at=2020-01-01T00:00:00Z" \
  render "$MF/nonl-birth" 0.4.0 2026-07-19T14:24:51Z
# And the preservation contract, whose whole subject is the file's tail: a
# later command's line is very often the last one written.
NONLF="$MF/nonl-foreign"
printf 'schema=1\nbootstrapped_by=0.4.0\nbootstrapped_at=2020-01-01T00:00:00Z\nconverged_by=0.4.0\nconverged_at=2020-01-01T00:00:00Z\nrunner_installed_at=2026-07-19T16:10:00Z' > "$NONLF"
check "manifest: an unterminated FOREIGN final line is not eaten by the rewrite" 0 "runner_installed_at=2026-07-19T16:10:00Z" \
  render "$NONLF" 0.4.0 2026-07-19T14:24:51Z
# Reading it correctly also REPAIRS it: the rewritten copy is newline-terminated,
# so an unterminated file converges to a terminated one exactly once and then
# reproduces itself like any other. Asserted as "the source, plus the newline it
# was missing, and NOTHING else" — a plain does-it-end-in-\n check would stay
# green on an implementation that dropped the final line, since a file with the
# tail eaten is newline-terminated too.
NORMALIZED="$MF/normalized"
render "$NONLF" 0.4.0 2026-07-19T14:24:51Z > "$NORMALIZED"
adds_only_the_newline() {   # adds_only_the_newline <source> <normalized>
  diff <(cat "$1"; printf '\n') "$2"
}
check "manifest: the rewrite adds the missing final newline and changes nothing else" 0 "" \
  adds_only_the_newline "$NONLF" "$NORMALIZED"
check "manifest: ...and the normalized file then settles" 0 "" \
  reproduces_itself "$NORMALIZED" 0.4.0
# Presence, not just value: manifest_has answers the absent-vs-empty question
# `rig manifest <key>` puts in its exit code, and it read the same short file.
has_key() {   # has_key <path> <key>
  ( set -euo pipefail
    . "$ROOT/commands/lib/manifest.sh"
    manifest_has "$1" "$2" )
}
check "manifest: an unterminated final key is PRESENT, not absent" 0 "" \
  has_key "$NONL" converged_at

# -- the version that RAN, not the one installed now ------------------------
# The whole point: a machine outlives the rig that built it, so this is read
# from the tree at run time and never re-derived from `rig --version` later.
check "manifest: the running version comes from the tree's own VERSION" 0 "$(cat "$ROOT/VERSION")" \
  running_version "$ROOT"
check "manifest: a tree with no VERSION records unknown, not an empty key" 0 "unknown" \
  running_version "$MF"

# -- the marker is NOT touched ----------------------------------------------
# /etc/rig/role has six readers, install.sh:82-90 among them; the manifest is a
# second file beside it, never a replacement. Assert the writer cannot reach it.
check "manifest: no CODE in the manifest lib reaches the role marker" 1 "" \
  grep -nE '^[^#]*(/etc/rig/role|RIG_ROLE_MARKER)' "$ROOT/commands/lib/manifest.sh"
check "bootstrap: the role marker write is still its own cmp-guarded block" 0 "" \
  grep -qE '^MARKER=/etc/rig/role$' "$ROOT/commands/bootstrap.sh"

# -- ordering: provenance is written after the tag verification -------------
# The marker's discipline, inherited verbatim — a manifest that survives a run
# which failed to become what it claims is a confident wrong answer.
mfstamp_at="$(grep -nE '^if manifest_stamp ' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
verify_at="$(grep -nE '^[[:space:]]*verify_effective_tag back-out$' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
check "bootstrap: both ordering anchors were found (guards the greps above)" 0 "" \
  test -n "${mfstamp_at:-}" -a -n "${verify_at:-}"
check "bootstrap: the manifest stamp follows the tag verification" 0 "" \
  test "${mfstamp_at:-0}" -gt "${verify_at:-999999}"
# Both bootstrap paths stamp it: a box-minted guest is a machine rig converged,
# and "which rig, when" is a fact whichever bootstrap ran.
check "bootstrap-tenant: a tenant gets a manifest too" 0 "" \
  grep -q 'manifest_stamp' "$ROOT/commands/bootstrap-tenant.sh"

# -- `rig manifest`, the reader ---------------------------------------------
key_prints_exactly() {   # key_prints_exactly <path> <key> <want>
  [ "$(RIG_MANIFEST="$1" "$ROOT/commands/manifest.sh" "$2")" = "$3" ]
}
check "manifest: --help exits 0" 0 "usage: rig manifest" "$ROOT/commands/manifest.sh" --help
check "manifest: dispatches through bin/rig" 0 "usage: rig manifest" "$ROOT/bin/rig" manifest --help
check "manifest: rig --help lists the command" 0 "manifest [<key>]" "$ROOT/bin/rig" --help
check "manifest: unknown flag exits 2" 2 "unknown option" \
  env RIG_MANIFEST="$STAMPED" "$ROOT/commands/manifest.sh" --nope
check "manifest: two keys is a usage error" 2 "at most one key" \
  env RIG_MANIFEST="$STAMPED" "$ROOT/commands/manifest.sh" converged_by schema
check "manifest: an absent manifest exits 1 by name" 1 "no manifest at" \
  env RIG_MANIFEST="$MF/absent" "$ROOT/commands/manifest.sh"
check "manifest: bare prints the file" 0 "converged_by=0.6.0" \
  env RIG_MANIFEST="$STAMPED" "$ROOT/commands/manifest.sh"
check "manifest: a key prints the value ALONE, for shell callers" 0 "" \
  key_prints_exactly "$STAMPED" converged_by 0.6.0
check "manifest: an unknown key exits 1 and names the keys present" 1 "keys present" \
  env RIG_MANIFEST="$STAMPED" "$ROOT/commands/manifest.sh" nosuchkey
# Operator input reaches the key lookup, so the lookup is a string equality and
# never a pattern — a key of '.*' must find nothing rather than match line one.
check "manifest: a regex-shaped key matches nothing" 1 "no such key" \
  env RIG_MANIFEST="$STAMPED" "$ROOT/commands/manifest.sh" '.*'
# The reader writes NOTHING — bootstrap is the manifest's single writer.
MTIME_BEFORE="$(mtime_of "$STAMPED")"
RIG_MANIFEST="$STAMPED" "$ROOT/commands/manifest.sh" >/dev/null 2>&1 || true
check "manifest: reading it does not write it" 0 "$MTIME_BEFORE" mtime_of "$STAMPED"

# Secrets: this file is 0644 by design, so the rule has to be stated where the
# next command that appends a line will read it (repo precedent:
# runner-install.sh:190's ".rig-labels — box-local metadata, never a credential").
check "manifest: the never-a-credential rule is stated in the writer" 0 "never a credential" \
  cat "$ROOT/commands/lib/manifest.sh"

rm -rf "$MF"

# ---------------------------------------------------------------------------
# The versioned install (box#79's layout, ported — #35). RIG_INSTALL_SOURCE
# bypasses the network, so these are REAL runs of install.sh against throwaway
# RIG_HOME/RIG_BIN roots — layout, symlink chain, flat-tree migration, symlink
# healing, use and uninstall are all DRIVEN, not grepped. The bootstrapped-host
# flip gate (rig's analog of box's #66 refusal: WARN, never refuse) is driven
# too, through RIG_ROLE_MARKER fixtures — no root, no network, no real marker.
# ---------------------------------------------------------------------------
check "install.sh is valid bash" 0 "" bash -n "$ROOT/install.sh"
VER="$(cat "$ROOT/VERSION")"
check "--version answers the tree's own VERSION" 0 "rig $VER" "$ROOT/bin/rig" --version
check "-V is --version" 0 "rig $VER" "$ROOT/bin/rig" -V
check "help lists the versioned verbs" 0 "uninstall" "$ROOT/bin/rig" --help

WORK="$(mktemp -d)"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"

# Every real installer run gets a deterministic registry archive. The curl
# shim can also be poisoned per call to prove warn-and-continue behavior.
SNAPBIN="$WORK/snapshot-bin"
mkdir -p "$SNAPBIN" "$WORK/snapshot-stage/rig-templates-pin/scratch-box"
printf 'USER="scratch"\n' > "$WORK/snapshot-stage/rig-templates-pin/scratch-box/template.env"
tar -czf "$WORK/snapshot.tar.gz" -C "$WORK/snapshot-stage" rig-templates-pin
cat > "$SNAPBIN/curl" <<'CURLEOF'
#!/usr/bin/env bash
[ -z "${SNAPSHOT_FETCH_FAIL:-}" ] || exit 22
cp "${SNAPSHOT_TARBALL:?}" "$4"
CURLEOF
chmod +x "$SNAPBIN/curl"

# A fabricated "newer release": the same CLI, a different VERSION — what an
# upgrade actually is, from the installer's point of view.
SRC9="$WORK/src-9.9.9"; mkdir -p "$SRC9/bin"
cp "$ROOT/bin/rig" "$SRC9/bin/rig"; chmod +x "$SRC9/bin/rig"
echo "9.9.9-drill" > "$SRC9/VERSION"
SRC8="$WORK/src-8.8.8"; mkdir -p "$SRC8/bin"
cp "$ROOT/bin/rig" "$SRC8/bin/rig"; chmod +x "$SRC8/bin/rig"
echo "8.8.8-drill" > "$SRC8/VERSION"

inst() {  # inst <rig_home> <rig_bin> [VAR=val ...] — run install.sh for real
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$SNAPBIN:$PATH" \
      SNAPSHOT_TARBALL="$WORK/snapshot.tar.gz" RIG_ROLE_MARKER="$WORK/no-marker" \
      RIG_HOME="$h" RIG_BIN="$b" \
      RIG_INSTALL_SOURCE="$ROOT" "$@" bash "$ROOT/install.sh"
}
irig() {  # irig [VAR=val ...] <cmd...> — run an installed rig, marker-free
  env HOME="$FAKEHOME" RIG_ROLE_MARKER="$WORK/no-marker" "$@"
}

# --- fresh install: the layout and the chain --------------------------------
H1="$WORK/h1"; B1="$WORK/b1"
check "install: a fresh install runs clean" 0 "done" inst "$H1" "$B1"
check "install: the tree lands in versions/<v>" 0 "" test -x "$H1/versions/$VER/bin/rig"
check "install: 'current' points at versions/<v>" 0 "versions/$VER" readlink "$H1/current"
check "install: the PATH symlink rides the chain" 0 "$H1/current/bin/rig" readlink "$B1/rig"
check "install: rig --version answers through the whole chain" 0 "rig $VER" irig "$B1/rig" --version
check "install: INSTALLED_FROM records the local source" 0 "local:" cat "$H1/versions/$VER/INSTALLED_FROM"
check "install: the pinned registry snapshot lands inside the version tree" 0 "" \
  test -f "$H1/versions/$VER/templates@$TPL_PIN/scratch-box/template.env"

HFAIL="$WORK/h-failed-snapshot"; BFAIL="$WORK/b-failed-snapshot"
check "install: unreachable registry warns and still installs rig" 0 "WARNING: could not fetch template registry snapshot" \
  inst "$HFAIL" "$BFAIL" SNAPSHOT_FETCH_FAIL=1
check "install: failed snapshot fetch leaves a working tree" 0 "rig $VER" \
  "$BFAIL/rig" --version
check "install: failed snapshot fetch leaves no hollow snapshot" 1 "" \
  test -e "$HFAIL/versions/$VER/templates@$TPL_PIN"

# --- rig#39: no $HOME in the environment (cloud-init's runcmd) ---------------
# The box#88 seed runs install.sh from runcmd, which carries NO $HOME; under
# set -u the first $HOME expansion was a death instead of an install. The
# installer now derives a home from getent — driven here with a shim getent
# so the derived home is a throwaway root, and proven fatal-BY-NAME when
# getent has no answer either (never a bare unbound-variable stack).
GESHIM="$WORK/geshim"; GEHOME="$WORK/gehome"; mkdir -p "$GESHIM" "$GEHOME"
printf '#!/bin/sh\necho "u:x:0:0::%s:/bin/sh"\n' "$GEHOME" > "$GESHIM/getent"
chmod +x "$GESHIM/getent"
check "install: no \$HOME derives one from getent (rig#39)" 0 "done" \
  env -u HOME PATH="$GESHIM:$PATH" RIG_ROLE_MARKER="$WORK/no-marker" \
      RIG_INSTALL_SOURCE="$ROOT" bash "$ROOT/install.sh"
check "install: ...and the tree landed under the derived home" 0 "" \
  test -x "$GEHOME/.local/share/rig/versions/$VER/bin/rig"
printf '#!/bin/sh\nexit 2\n' > "$GESHIM/getent"
check "install: no \$HOME and no getent answer refuses by name" 1 "set HOME and re-run" \
  env -u HOME PATH="$GESHIM:$PATH" RIG_ROLE_MARKER="$WORK/no-marker" \
      RIG_INSTALL_SOURCE="$ROOT" bash "$ROOT/install.sh"

# --- converge, don't clobber ------------------------------------------------
touch "$H1/versions/$VER/CANARY"
touch "$H1/versions/$VER/templates@$TPL_PIN/STALE"
check "install: a same-version re-run is a no-op that says so" 0 "already installed" inst "$H1" "$B1"
check "install: the no-op left the tree untouched" 0 "" test -e "$H1/versions/$VER/CANARY"
check "install: RIG_REINSTALL=1 replaces that version's tree" 0 "reinstalled" inst "$H1" "$B1" RIG_REINSTALL=1
check "install: the reinstall really replaced it (canary gone)" 1 "" test -e "$H1/versions/$VER/CANARY"
check "install: reinstall replaces the registry snapshot" 1 "" \
  test -e "$H1/versions/$VER/templates@$TPL_PIN/STALE"

# --- a second version: side-by-side, and the flip ---------------------------
check "install: a second version installs side-by-side" 0 "" inst "$H1" "$B1" RIG_INSTALL_SOURCE="$SRC9"
check "install: ...into its own versions dir" 0 "" test -x "$H1/versions/9.9.9-drill/bin/rig"
check "install: ...and the old version stays" 0 "" test -d "$H1/versions/$VER"
check "install: the default flips to the new version" 0 "rig 9.9.9-drill" irig "$B1/rig" --version

# --- rig versions -----------------------------------------------------------
check "versions: lists the installed versions" 0 "$VER" irig "$B1/rig" versions
check "versions: marks the current default" 0 "(current)" irig "$B1/rig" versions
check "versions: marks the running one" 0 "(running)" irig "$B1/rig" versions

# --- rig use ----------------------------------------------------------------
check "use: no argument is a usage error" 2 "use needs a version" irig "$B1/rig" use
check "use: an unknown version is refused by name" 1 "no such version" irig "$B1/rig" use 1.2.3
# A version is a directory NAME — a crafted one must die at the gate, never
# reach the ln (current pointing outside the root) or an rm -rf.
check "use: a path-traversal version dies at the gate" 1 "not a sane version name" \
  irig "$B1/rig" use '../../tmp/evil'
check "use: flips the default" 0 "switched to $VER" irig "$B1/rig" use "$VER"
check "use: the flip is effective through the PATH chain" 0 "rig $VER" irig "$B1/rig" --version
check "install: an installed-but-not-current version is a no-op too" 0 "already installed" \
  inst "$H1" "$B1" RIG_INSTALL_SOURCE="$SRC9"
check "install: ...and does not move the default" 0 "rig $VER" irig "$B1/rig" --version

# --- the flip gate: a bootstrapped host WARNS, never refuses (#35) ----------
# box refuses version flips under existing boxes; rig's stake is the converged
# host itself — /etc/rig/role. The deliberate decision: warn and proceed.
# Driven against a fixture marker; counting fires proves silence too.
MARK="$WORK/role-marker"
printf 'role=workload-server root-door=open host=no join=authkey\n' > "$MARK"
H2="$WORK/h2"; B2="$WORK/b2"
check "flip gate: baseline install" 0 "done" inst "$H2" "$B2"
check "flip gate: an upgrade on a bootstrapped host WARNS" 0 "this host is bootstrapped" \
  inst "$H2" "$B2" RIG_INSTALL_SOURCE="$SRC9" RIG_ROLE_MARKER="$MARK"
check "flip gate: ...and still flips (warn, not refuse)" 0 "rig 9.9.9-drill" irig "$B2/rig" --version
check "flip gate: 'rig use' on a bootstrapped host WARNS" 0 "this host is bootstrapped" \
  irig RIG_ROLE_MARKER="$MARK" "$B2/rig" use "$VER"
check "flip gate: ...and still flips" 0 "rig $VER" irig "$B2/rig" --version
# Silence when no marker: warning every un-bootstrapped host would train
# operators to ignore it.
flip_warns() { # flip_warns <cmd...> — how many bootstrapped warnings fired
  "$@" 2>&1 | grep -c "this host is bootstrapped" || true
}
check "flip gate: no marker, no warning (installer)" 0 "0" \
  flip_warns inst "$H2" "$B2" RIG_INSTALL_SOURCE="$SRC9"
check "flip gate: no marker, no warning (rig use)" 0 "0" \
  flip_warns irig "$B2/rig" use "$VER"
check "flip gate: a fresh install never warns (nothing changes under the host)" 0 "0" \
  flip_warns inst "$WORK/h2f" "$WORK/b2f" RIG_ROLE_MARKER="$MARK"

# --- migration: a flat pre-versioning tree becomes a versioned one ----------
H3="$WORK/h3"; B3="$WORK/b3"; mkdir -p "$H3/bin" "$B3"
cp "$ROOT/bin/rig" "$H3/bin/rig"; chmod +x "$H3/bin/rig"
cp "$ROOT/VERSION" "$H3/VERSION"
echo "test@flat" > "$H3/INSTALLED_FROM"
ln -s "$H3/bin/rig" "$B3/rig"
check "migrate: a flat tree is moved into versions/" 0 "migrating" inst "$H3" "$B3"
check "migrate: the OPERATOR'S tree moved (not a fresh copy)" 0 "test@flat" \
  cat "$H3/versions/$VER/INSTALLED_FROM"
check "migrate: nothing flat remains at the root" 1 "" test -e "$H3/bin"
check "migrate: current points at the migrated version" 0 "versions/$VER" readlink "$H3/current"
check "migrate: the PATH symlink was re-pointed through current" 0 "$H3/current/bin/rig" readlink "$B3/rig"
check "migrate: the migrated install answers --version" 0 "rig $VER" irig "$B3/rig" --version

# ...and the seamless upgrade every REAL flat rig install takes: no VERSION
# file at all (pre-rig#32), so it migrates as 0.0.0-unknown and the new
# version lands beside it and becomes the default.
H4="$WORK/h4"; B4="$WORK/b4"; mkdir -p "$H4/bin" "$B4"
cp "$ROOT/bin/rig" "$H4/bin/rig"; chmod +x "$H4/bin/rig"
ln -s "$H4/bin/rig" "$B4/rig"
check "migrate: a VERSION-less flat tree migrates as 0.0.0-unknown" 0 "0.0.0-unknown" \
  inst "$H4" "$B4" RIG_INSTALL_SOURCE="$SRC9"
check "migrate+upgrade: both versions present" 0 "" \
  bash -c "[ -d '$H4/versions/0.0.0-unknown' ] && [ -d '$H4/versions/9.9.9-drill' ]"
check "migrate+upgrade: the new version is the default" 0 "rig 9.9.9-drill" \
  irig "$B4/rig" --version

# A broken current must halt the single-version uninstall BEFORE any decision:
# the CURRENT guard keys off what current resolves to, and a dangling link
# makes that answer a lie. Drive the version tree's own binary — the current
# chain is exactly what is broken. Heal current afterwards.
ln -sfn "versions/gone" "$H4/current"
check "uninstall: refuses while current is dangling (heal before delete)" 1 "dangling" \
  irig "$H4/versions/9.9.9-drill/bin/rig" uninstall 0.0.0-unknown --force
check "uninstall: ...and both version trees survived the refusal" 0 "" \
  bash -c "[ -d '$H4/versions/0.0.0-unknown' ] && [ -d '$H4/versions/9.9.9-drill' ]"
ln -sfn "versions/9.9.9-drill" "$H4/current"

# The migration reads VERSION off the old tree — disk data, not installer
# data. A hostile value must refuse BEFORE the tree moves anywhere.
H9="$WORK/h9"; B9="$WORK/b9"; mkdir -p "$H9/bin" "$B9"
cp "$ROOT/bin/rig" "$H9/bin/rig"; chmod +x "$H9/bin/rig"
printf '%s\n' '../pwn' > "$H9/VERSION"
check "migrate: a hostile flat VERSION refuses to migrate" 1 "not a sane directory name" \
  inst "$H9" "$B9"
check "migrate: ...with the flat tree untouched where it was" 0 "" test -x "$H9/bin/rig"

# --- healing: a wedged $BINDIR/rig must never block an install --------------
H5="$WORK/h5"; B5="$WORK/b5"; mkdir -p "$B5"
ln -s "$WORK/nowhere/rig" "$B5/rig"                    # dangling
check "heal: a DANGLING \$BINDIR/rig does not wedge the install" 0 "done" inst "$H5" "$B5"
check "heal: ...and got repointed" 0 "rig $VER" irig "$B5/rig" --version
H6="$WORK/h6"; B6="$WORK/b6"; mkdir -p "$B6"
ln -s /bin/true "$B6/rig"                              # stale, but resolvable
check "heal: a STALE \$BINDIR/rig with no tree does not fake 'installed'" 0 "installing $VER" \
  inst "$H6" "$B6"
check "heal: ...the install is real and answers" 0 "rig $VER" irig "$B6/rig" --version

# --- rig uninstall: one version ---------------------------------------------
check "uninstall: refuses to remove the CURRENT version" 1 "CURRENT" \
  irig "$B1/rig" uninstall "$VER" --force
check "uninstall: an unknown version is refused by name" 1 "no such version" \
  irig "$B1/rig" uninstall 5.5.5 --force
check "uninstall: a path-traversal version dies at the gate (never an rm -rf)" 1 "not a sane version name" \
  irig "$B1/rig" uninstall '../../../../etc' --force
check "uninstall: a version plus --all is ambiguous (usage error)" 2 "ambiguous" \
  irig "$B1/rig" uninstall 9.9.9-drill --all --force
check "uninstall: an unknown flag is refused" 2 "unknown option" \
  irig "$B1/rig" uninstall --nope
check "uninstall: removes a non-current version" 0 "removed version" \
  irig "$B1/rig" uninstall 9.9.9-drill --force
check "uninstall: that version dir is gone" 1 "" test -e "$H1/versions/9.9.9-drill"
check "uninstall: the current version still answers" 0 "rig $VER" irig "$B1/rig" --version

# --- rig uninstall: everything ----------------------------------------------
check "uninstall: refuses without --force when no terminal" 2 "refusing" \
  irig bash -c "'$B1/rig' uninstall --all </dev/null"
check "uninstall --all: warns on a bootstrapped host (never refuses)" 0 "this host is bootstrapped" \
  irig RIG_ROLE_MARKER="$MARK" "$B1/rig" uninstall --all --force
check "uninstall --all: removed the whole install" 0 "" bash -c "
  [ ! -e '$H1' ] && [ ! -L '$H1' ] &&
  [ ! -e '$B1/rig' ] && [ ! -L '$B1/rig' ]"
# ...and RIG_YES=1 is the installer-family consent (no --force, no tty).
check "uninstall --all: RIG_YES=1 is consent without a terminal" 0 "uninstalled" \
  irig bash -c "RIG_YES=1 '$B2/rig' uninstall --all </dev/null"
check "uninstall --all: ZERO residue — root and symlinks" 0 "" bash -c "
  [ ! -e '$H2' ] && [ ! -L '$H2' ] &&
  [ ! -e '$B2/rig' ] && [ ! -L '$B2/rig' ]"
# --- the INTERACTIVE confirm, driven through a real pty (#68) ---------------
# uninstall_confirm only reaches its `read` when stdin is a terminal, which is
# why every check above goes through --force or RIG_YES and why the EOF bug
# survived. `script` gives us the terminal. Assert on the MESSAGE, never on the
# exit code: the unfixed `read -r reply` (no `|| reply=""`) dies at the read
# under `set -e` and also exits 1, just silently — an exit-code assertion is
# green against the bug and proves nothing.
if command -v script >/dev/null 2>&1; then
  H8="$WORK/h8"; B8="$WORK/b8"
  inst "$H8" "$B8" >/dev/null 2>&1
  check "uninstall: Ctrl-D at the confirm prompt ABORTS OUT LOUD (#68)" 1 "aborted." \
    irig bash -c "script -qec \"'$B8/rig' uninstall --all\" /dev/null </dev/null"
  check "uninstall: ...and the EOF abort removed nothing" 0 "" \
    bash -c "[ -e '$H8' ] && [ -e '$B8/rig' ]"
  printf 'y\n' > "$WORK/yes-in"
  check "uninstall: 'y' at the confirm prompt goes through" 0 "uninstalled" \
    irig bash -c "script -qec \"'$B8/rig' uninstall --all\" /dev/null < '$WORK/yes-in'"
  check "uninstall: ...and that really removed the install" 0 "" \
    bash -c "[ ! -e '$H8' ] && [ ! -e '$B8/rig' ]"
else
  echo "skip: interactive uninstall confirm drills (no util-linux script)"
fi

# The last word is a re-check: a survivor must turn into a loud INCOMPLETE,
# never a cheerful "uninstalled". (Root ignores file modes, so this drill is
# meaningful — and runnable — for a non-root runner only.)
if [ "$(id -u)" -ne 0 ]; then
  H7="$WORK/h7"; B7="$WORK/b7"
  inst "$H7" "$B7" >/dev/null 2>&1
  mkdir -p "$H7/versions/$VER/stuck"; touch "$H7/versions/$VER/stuck/pin"
  chmod 555 "$H7/versions/$VER/stuck"
  check "uninstall: a survivor makes it scream INCOMPLETE (exit 1)" 1 "INCOMPLETE" \
    irig "$B7/rig" uninstall --all --force
  chmod -R u+w "$H7" 2>/dev/null
else
  echo "skip: uninstall INCOMPLETE drill (root ignores file modes)"
fi

# --- the versioned verbs from a working tree: refuse, don't guess -----------
check "uninstall: refuses from a working tree" 1 "not a versioned install" "$ROOT/bin/rig" uninstall --all --force
check "versions: refuses from a working tree" 1 "not a versioned install" "$ROOT/bin/rig" versions
check "use: refuses from a working tree" 1 "not a versioned install" "$ROOT/bin/rig" use 1.0.0

# The version-name gate must be ONE decision: install.sh and bin/rig carry
# byte-identical copies (the installer runs before any tree exists), and a
# drifted copy is two gates pretending to be one — a version install.sh would
# refuse must not be one 'rig use' accepts.
VVBIN="$(mktemp)"; VVINST="$(mktemp)"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/bin/rig"     > "$VVBIN"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$VVINST"
check "valid_version: extracted from bin/rig (guards the awk)" 0 "A-Za-z0-9" cat "$VVBIN"
check "valid_version: bin/rig and install.sh copies are byte-identical" 0 "" diff "$VVBIN" "$VVINST"
rm -f "$VVBIN" "$VVINST"
# Same discipline for the flip gate: one bootstrapped-host stance, two copies.
WBBIN="$(mktemp)"; WBINST="$(mktemp)"
awk '/^warn_bootstrapped\(\) \{/,/^\}/' "$ROOT/bin/rig"     > "$WBBIN"
awk '/^warn_bootstrapped\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$WBINST"
check "warn_bootstrapped: extracted from bin/rig (guards the awk)" 0 "RIG_ROLE_MARKER" cat "$WBBIN"
check "warn_bootstrapped: bin/rig and install.sh copies are byte-identical" 0 "" diff "$WBBIN" "$WBINST"
rm -f "$WBBIN" "$WBINST"

rm -rf "$WORK"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
