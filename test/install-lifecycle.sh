#!/usr/bin/env bash
# The install LIFECYCLE, driven end to end against a tree install.sh itself
# produced (#106) — the four beats box and cast already run in CI, which rig,
# the repo whose headline claim is convergence, ran nowhere:
#
#   1. install from THIS checkout      (RIG_INSTALL_SOURCE — the local channel)
#   2. assert what landed              (layout, current, the PATH chain)
#   3. a converging re-run             (an EMPTY DIFF, never an exit code)
#   4. uninstall --all                 (ending in the absence assert)
#
# test/cli.sh drives the same verbs against throwaway roots; this suite runs
# them in the environment cli.sh deliberately fakes — the real default paths
# under the runner's own $HOME. Run: bash test/install-lifecycle.sh (CI's
# `install:` job). RIG_HOME/RIG_BIN redirect the roots for a local run; the
# refusal below explains when you need them.
#
# Deliberately no `set -e` — a failing beat is data, and the summary is the
# verdict (the test/release.sh harness shape).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
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

# The roots install.sh will use, computed by ITS rules (install.sh:55-60), so
# every assert below points at what the installer actually touched.
DEST="${RIG_HOME:-$HOME/.local/share/rig}"
if [ "$(id -u)" -eq 0 ]; then
  BINDIR="${RIG_BIN:-/usr/local/bin}"
else
  BINDIR="${RIG_BIN:-$HOME/.local/bin}"
fi

# Beat 4 REMOVES the install at those roots, so a rig that already lives there
# is a refusal, not a fixture — this suite must never eat an operator's
# install. CI runners are clean; a workstation run points the roots at
# something disposable.
if [ -e "$DEST" ] || [ -L "$DEST" ] || [ -e "$BINDIR/rig" ] || [ -L "$BINDIR/rig" ]; then
  echo "install-lifecycle: a rig install already exists ($DEST or $BINDIR/rig)" >&2
  echo "install-lifecycle: refusing to drive the lifecycle over it — re-run against scratch roots:" >&2
  echo "  W=\$(mktemp -d); RIG_HOME=\$W/rig RIG_BIN=\$W/bin bash test/install-lifecycle.sh" >&2
  exit 2
fi

VER="$(cat "$ROOT/VERSION")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# install.sh snapshots the pinned registry even for the local source channel.
# Serve a deterministic archive so this lifecycle remains fully offline.
SNAPBIN="$WORK/snapshot-bin"
mkdir -p "$SNAPBIN" "$WORK/snapshot-stage/rig-templates-pin/test-box"
printf 'USER="test"\n' > "$WORK/snapshot-stage/rig-templates-pin/test-box/template.env"
tar -czf "$WORK/snapshot.tar.gz" -C "$WORK/snapshot-stage" rig-templates-pin
cat > "$SNAPBIN/curl" <<'CURLEOF'
#!/usr/bin/env bash
cp "${SNAPSHOT_TARBALL:?}" "$4"
CURLEOF
chmod +x "$SNAPBIN/curl"

# tree_state <root> — what "changed nothing" must mean: every file's bytes,
# every path's type and mode, every symlink's target. Beat 3 captures this
# before and after the re-run and diffs the two.
tree_state() {
  (cd "$1" || return 1
   find . -type f -exec sha256sum {} + | LC_ALL=C sort
   find . -type l -printf '%p -> %l\n' | LC_ALL=C sort
   find . -printf '%y %m %p\n' | LC_ALL=C sort)
}

diff_state() {  # diff_state <capture> <root> — how the tree drifted, by name
  tree_state "$2" | diff "$1" -
}

no_residue() {  # no_residue <path>... — 0 iff every path is GONE: file, dir OR
  local p bad=0 # symlink. `! -e` alone follows the link and cannot see it
  for p in "$@"; do  # dangling — the residue a broken uninstall actually leaves.
    if [ -e "$p" ] || [ -L "$p" ]; then echo "still present: $p"; bad=1; fi
  done
  return "$bad"
}

# --- instrument honesty ------------------------------------------------------
# The diff and the absence assert must be able to FAIL, or beats 3 and 4 prove
# nothing — so break each one against a scratch tree first, on every run
# (the test/drill.sh doctrine: mechanical, not a one-off claim in a PR).
SCR="$WORK/scr"; mkdir -p "$SCR/tree/bin"
echo content > "$SCR/tree/bin/rig"
ln -s bin/rig "$SCR/tree/link"
tree_state "$SCR/tree" > "$SCR/cap"
check "honesty: an untouched tree reads as zero drift" 0 "" \
  diff_state "$SCR/cap" "$SCR/tree"
echo drift >> "$SCR/tree/bin/rig"
check "honesty: a mutated file is drift, named" 1 "bin/rig" \
  diff_state "$SCR/cap" "$SCR/tree"
tree_state "$SCR/tree" > "$SCR/cap"
ln -sfn ../elsewhere "$SCR/tree/link"
check "honesty: a retargeted symlink is drift" 1 "elsewhere" \
  diff_state "$SCR/cap" "$SCR/tree"
tree_state "$SCR/tree" > "$SCR/cap"
touch "$SCR/tree/leftover"
check "honesty: an ADDED file is drift (what a non-convergent installer leaves)" 1 "leftover" \
  diff_state "$SCR/cap" "$SCR/tree"
# The beat-4 distinction, demonstrated: `test ! -e` PASSES on a dangling
# symlink (it follows the link), so on its own it would certify a broken
# uninstall clean — only `! -L` sees the corpse.
ln -s "$SCR/nowhere" "$SCR/dangling-rig"
check "honesty: test ! -e cannot see a dangling symlink (the lie)" 0 "" \
  test ! -e "$SCR/dangling-rig"
check "honesty: the absence assert can (! -L is the catch)" 1 "still present" \
  no_residue "$SCR/dangling-rig"
rm "$SCR/dangling-rig"
check "honesty: a really-gone path passes the absence assert" 0 "" \
  no_residue "$SCR/dangling-rig"

# --- beat 1: install from THIS checkout --------------------------------------
# RIG_INSTALL_SOURCE is the supported local channel (its contract — dir,
# tarball, loud refusal, no silent download fallback — is test/release.sh's);
# in CI $ROOT is $GITHUB_WORKSPACE, so what lands is the code under review.
b1() {
  PATH="$SNAPBIN:$PATH" SNAPSHOT_TARBALL="$WORK/snapshot.tar.gz" \
    RIG_INSTALL_SOURCE="$ROOT" bash "$ROOT/install.sh"
}
check "beat 1: install.sh installs this checkout" 0 "done" b1

# --- beat 2: assert what landed ----------------------------------------------
check "beat 2: the tree landed in versions/$VER" 0 "" \
  test -x "$DEST/versions/$VER/bin/rig"
check "beat 2: current points at versions/$VER" 0 "versions/$VER" \
  readlink "$DEST/current"
check "beat 2: the PATH symlink rides the chain" 0 "$DEST/current/bin/rig" \
  readlink "$BINDIR/rig"
check "beat 2: ...and resolves into versions/ (cast's assert)" 0 "/versions/$VER/bin/rig" \
  readlink -f "$BINDIR/rig"
check "beat 2: rig --version answers through the whole chain" 0 "rig $VER" \
  "$BINDIR/rig" --version
check "beat 2: INSTALLED_FROM names the local source" 0 "local:$ROOT" \
  cat "$DEST/versions/$VER/INSTALLED_FROM"
TPL_PIN="$(sed -n 's/^RIG_TEMPLATES_PIN=//p' "$ROOT/commands/lib/templates.sh")"
check "beat 2: pinned registry snapshot landed in the version tree" 0 "" \
  test -f "$DEST/versions/$VER/templates@$TPL_PIN/test-box/template.env"

# --- beat 3: the converging re-run -------------------------------------------
# "Ran twice without crashing" is the self-deception this beat exists to
# refuse (#106): the assert is an empty diff of captured state, plus current
# still pointing where it did.
tree_state "$DEST" > "$WORK/before"
CUR_BEFORE="$(readlink "$DEST/current")"
check "beat 3: the re-run is a no-op that says so" 0 "already installed" b1
check "beat 3: ...and changed NOTHING — the diff is the verdict" 0 "" \
  diff_state "$WORK/before" "$DEST"
check "beat 3: current did not move" 0 "" \
  test "$(readlink "$DEST/current")" = "$CUR_BEFORE"

# --- beat 4: uninstall --all, ending in the absence assert -------------------
check "beat 4: uninstall --all removes the whole install" 0 "uninstalled" \
  "$BINDIR/rig" uninstall --all --force
check "beat 4: zero residue at the install root" 0 "" no_residue "$DEST"
check "beat 4: zero residue on PATH — not even a dangling symlink" 0 "" \
  no_residue "$BINDIR/rig"
# The doctrine spelled out as its two distinct asserts (#106): -e for
# presence, -L for the dangling link -e cannot see.
check "beat 4: test ! -e on the PATH entry" 0 "" test ! -e "$BINDIR/rig"
check "beat 4: test ! -L on the PATH entry" 0 "" test ! -L "$BINDIR/rig"
check "beat 4: test ! -e on the install root" 0 "" test ! -e "$DEST"
check "beat 4: test ! -L on the install root" 0 "" test ! -L "$DEST"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
