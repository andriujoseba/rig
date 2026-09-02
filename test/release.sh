#!/usr/bin/env bash
# Rig's own half of the release surface (#32; trimmed in ceremony#13's
# conversion): latest-tag resolution and the installer's three channels.
# The machinery halves — changelog extraction, the arming rule,
# monotonicity, the drill gate, the workflow-shape pins — moved to
# heavy-duty/ceremony, which tests them in its own test/; what stays is
# everything that drives rig's install.sh and bin/. Dependency-free and
# NETWORK-FREE — wherever the code under test would call curl, the curl on
# PATH is a stub this harness wrote. Run: bash test/release.sh
# Deliberately no `set -e` — the harness asserts on failing commands.
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

WORK="$(mktemp -d)"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"


# --- the installer's ref logic, extracted ------------------------------------
# install.sh must stay a single curl|bash file, so its channel functions live
# inline; extract them here and drive them for real (the valid_version awk
# idiom from test/cli.sh), against a stub curl — never the network.
RL="$WORK/installer-fns.sh"
awk '/^resolve_latest_tag\(\) \{/,/^\}/' "$ROOT/install.sh" > "$RL"
awk '/^ref_candidate_urls\(\) \{/,/^\}/' "$ROOT/install.sh" >> "$RL"
check "installer fns extracted (guards the awk)" 0 "redirect_url" cat "$RL"

STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'CURL'
#!/usr/bin/env bash
# The harness's curl — never the network. Scripted via env:
#   CURL_STUB_FAIL      nonempty -> every call exits 22 (curl's HTTP error)
#   CURL_STUB_REDIRECT  what -w %{redirect_url} answers (the HEAD probe)
#   CURL_STUB_OK        substring a download URL must carry to succeed
#   CURL_STUB_TARBALL   copied to -o's target on a successful download
#   CURL_STUB_LOG       every URL asked for, one per line, appended
set -u
out="" url="" probe=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) probe=1; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -n "${CURL_STUB_LOG:-}" ]; then printf '%s\n' "$url" >> "$CURL_STUB_LOG"; fi
if [ -n "${CURL_STUB_FAIL:-}" ]; then exit 22; fi
if [ "$probe" -eq 1 ]; then printf '%s' "${CURL_STUB_REDIRECT:-}"; exit 0; fi
case "$url" in
  *"${CURL_STUB_OK:-/__nothing_succeeds__/}"*) cp "${CURL_STUB_TARBALL:?}" "${out:?}"; exit 0 ;;
  *) exit 22 ;;
esac
CURL
chmod +x "$STUB/curl"

rlt() { # rlt [VAR=val ...] — resolve_latest_tag under the stub curl
  # The single-quoted $1 is the inner bash's positional, not this shell's.
  # shellcheck disable=SC2016
  env PATH="$STUB:$PATH" "$@" bash -c 'set -euo pipefail
    . "$1"; resolve_latest_tag heavy-duty/rig' _ "$RL"
}
check "resolve: a releases/tag redirect yields the tag" 0 "0.1.0" \
  rlt CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases/tag/0.1.0
# A repo with NO releases redirects to /releases (measured live against
# heavy-duty/rig itself) — that must fail, never invent a ref.
check "resolve: the no-releases redirect (/releases) fails" 1 "" \
  rlt CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases
check "resolve: no redirect at all fails" 1 "" rlt
check "resolve: a tagless releases/tag/ redirect fails" 1 "" \
  rlt CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases/tag/
check "resolve: a failing curl fails (network down is not a channel)" 1 "" \
  rlt CURL_STUB_FAIL=1

rcu_line() { # rcu_line <n> — the nth candidate URL for an explicit ref
  bash -c 'set -euo pipefail
    . "$1"; ref_candidate_urls acme/widgets 1.2.3 | sed -n "${2}p"' _ "$RL" "$1"
}
check "candidates: refs/tags first — the pin outranks a same-named branch" 0 \
  "https://github.com/acme/widgets/archive/refs/tags/1.2.3.tar.gz" rcu_line 1
check "candidates: refs/heads is the fallback" 0 \
  "https://github.com/acme/widgets/archive/refs/heads/1.2.3.tar.gz" rcu_line 2

# --- the three channels, driven through the REAL installer -------------------
# Full install.sh runs against throwaway roots with the stub curl on PATH: the
# channel selection, the tag-first fallback, and the loud no-releases refusal
# are all DRIVEN, not grepped (the test/cli.sh install-drill idiom).
TBDIR="$WORK/tb"; mkdir -p "$TBDIR/rig-7.7.7-relflow/bin"
cp "$ROOT/bin/rig" "$TBDIR/rig-7.7.7-relflow/bin/rig"
chmod +x "$TBDIR/rig-7.7.7-relflow/bin/rig"
echo "7.7.7-relflow" > "$TBDIR/rig-7.7.7-relflow/VERSION"
tar -C "$TBDIR" -czf "$WORK/release.tgz" rig-7.7.7-relflow

rinst() { # rinst <home> <bin> [VAR=val ...] — a real install.sh run, stubbed net
  local h="$1" b="$2"; shift 2
  env -u RIG_REF PATH="$STUB:$PATH" HOME="$FAKEHOME" \
      RIG_ROLE_MARKER="$WORK/no-marker" RIG_HOME="$h" RIG_BIN="$b" \
      CURL_STUB_TARBALL="$WORK/release.tgz" "$@" bash "$ROOT/install.sh"
}

# Channel 1 — RIG_REF unset, a release exists: resolve the tag, download
# refs/tags/<tag>, and the installed tree records exactly that ref.
H1="$WORK/h1"; B1="$WORK/b1"
check "channel latest: resolves and installs the release tag" 0 "done" \
  rinst "$H1" "$B1" \
    CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases/tag/7.7.7-relflow \
    CURL_STUB_OK=refs/tags/7.7.7-relflow
check "channel latest: the tree landed under the tag's version" 0 "" \
  test -x "$H1/versions/7.7.7-relflow/bin/rig"
check "channel latest: INSTALLED_FROM names the resolved tag" 0 \
  "heavy-duty/rig@7.7.7-relflow" cat "$H1/versions/7.7.7-relflow/INSTALLED_FROM"

# Channel 1, transitional — RIG_REF unset, NO release exists (rig today):
# fail LOUDLY, name RIG_REF=main as the way out, install nothing. The stub
# would happily serve refs/heads/main here — a silent fallback would pass the
# download and FAIL this check by succeeding.
H2="$WORK/h2"; B2="$WORK/b2"
check "channel latest: no releases yet — dies, never hangs, never falls back" \
  1 "RIG_REF=main" rinst "$H2" "$B2" \
    CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases \
    CURL_STUB_OK=refs/heads/main
check "channel latest: the refusal says what is missing" 1 "no release" \
  rinst "$H2" "$B2" CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases
check "channel latest: the refusal installed NOTHING" 1 "" test -e "$H2"

# Channel 2 — RIG_REF=<tag>: refs/tags wins, and the latest-release probe is
# never consulted (a pin resolves nothing).
H3="$WORK/h3"; B3="$WORK/b3"; LOG3="$WORK/log3"
check "channel pinned: RIG_REF=<tag> installs from refs/tags" 0 "refs/tags/7.7.7-relflow" \
  rinst "$H3" "$B3" RIG_REF=7.7.7-relflow \
    CURL_STUB_OK=refs/tags/7.7.7-relflow CURL_STUB_LOG="$LOG3"
check "channel pinned: no releases/latest probe for an explicit ref" 1 "" \
  grep -q "releases/latest" "$LOG3"
check "channel pinned: exactly one download (the tag hit first)" 0 "1" \
  grep -c . "$LOG3"

# Channel 3 — RIG_REF=<branch>: the tag candidate misses, refs/heads lands.
H4="$WORK/h4"; B4="$WORK/b4"; LOG4="$WORK/log4"
check "channel dev: a branch ref falls back to refs/heads" 0 "done" \
  rinst "$H4" "$B4" RIG_REF=feature-x \
    CURL_STUB_OK=refs/heads/feature-x CURL_STUB_LOG="$LOG4"
check "channel dev: the tag URL was still tried FIRST" 0 "refs/tags/feature-x" \
  sed -n 1p "$LOG4"
check "channel dev: ...then the branch URL" 0 "refs/heads/feature-x" \
  sed -n 2p "$LOG4"

# Neither a tag nor a branch: both candidates miss, and the die says so.
H5="$WORK/h5"; B5="$WORK/b5"
check "channel: a ref that is neither tag nor branch dies naming both tries" \
  1 "not a tag and not a branch" rinst "$H5" "$B5" RIG_REF=no-such-ref

# --- the local channel: RIG_INSTALL_SOURCE (#106) ----------------------------
# A supported input, not test scaffolding — CI's `install:` job and test/cli.sh
# both install THIS checkout through it. What release.sh owes is the channel's
# contract: a directory installs, a tarball installs, neither touches the
# network, and a bad path refuses BY NAME — never a silent fallback to
# downloading a release, which would leave a green CI job testing the wrong
# tree. The stub curl's log is the network witness: any download, even an
# attempted one, would land a URL in it.
H6="$WORK/h6"; B6="$WORK/b6"; LOG6="$WORK/log6"
check "channel local: a directory installs" 0 "done" \
  rinst "$H6" "$B6" RIG_INSTALL_SOURCE="$TBDIR/rig-7.7.7-relflow" CURL_STUB_LOG="$LOG6"
check "channel local: the tree landed under its VERSION" 0 "" \
  test -x "$H6/versions/7.7.7-relflow/bin/rig"
check "channel local: INSTALLED_FROM records local:<path>" 0 \
  "local:$TBDIR/rig-7.7.7-relflow" cat "$H6/versions/7.7.7-relflow/INSTALLED_FROM"
check "channel local: curl was never consulted" 1 "" test -s "$LOG6"
H7="$WORK/h7"; B7="$WORK/b7"; LOG7="$WORK/log7"
check "channel local: a tarball installs too" 0 "done" \
  rinst "$H7" "$B7" RIG_INSTALL_SOURCE="$WORK/release.tgz" CURL_STUB_LOG="$LOG7"
check "channel local: the tarball's tree landed" 0 "" \
  test -x "$H7/versions/7.7.7-relflow/bin/rig"
check "channel local: ...also without a download" 1 "" test -s "$LOG7"
H8="$WORK/h8"; B8="$WORK/b8"; LOG8="$WORK/log8"
check "channel local: a missing path refuses BY NAME" 1 "$WORK/no-such-source" \
  rinst "$H8" "$B8" RIG_INSTALL_SOURCE="$WORK/no-such-source" CURL_STUB_LOG="$LOG8"
check "channel local: the refusal installed NOTHING" 1 "" test -e "$H8"
check "channel local: ...and downloaded nothing (no silent fallback)" 1 "" \
  test -s "$LOG8"

H9="$WORK/h9"; B9="$WORK/b9"; LOG9="$WORK/log9"
check "channel local: an artifact may override the temporary source provenance" 0 "done" \
  rinst "$H9" "$B9" RIG_INSTALL_SOURCE="$TBDIR/rig-7.7.7-relflow" \
    RIG_INSTALLED_FROM="artifact:rig-7.7.7-relflow.sh sha256:abc123" CURL_STUB_LOG="$LOG9"
check "channel local: the override is recorded exactly" 0 \
  "artifact:rig-7.7.7-relflow.sh sha256:abc123" \
  cat "$H9/versions/7.7.7-relflow/INSTALLED_FROM"
H10="$WORK/h10"; B10="$WORK/b10"
check "channel local: a multiline provenance value is refused" 1 \
  "RIG_INSTALLED_FROM must be one line" \
  rinst "$H10" "$B10" RIG_INSTALL_SOURCE="$TBDIR/rig-7.7.7-relflow" \
    "RIG_INSTALLED_FROM=artifact:one
forged:two"
check "channel local: the multiline refusal installs nothing" 1 "" test -e "$H10"

# --- generic self-installer builder (#219) ----------------------------------
# Drive the copied builder with a non-rig product. Product-specific source or
# provenance variables cannot hide behind this repository's own happy path.
MAKE_INSTALLER="$ROOT/dist/make-installer.sh"
ARTWORK="$WORK/generic-artifact"
ARTTREE="$ARTWORK/widget-tree"
ARTIFACT="$ARTWORK/widget-1.2.3.sh"
ARTLOG="$ARTWORK/installed"
mkdir -p "$ARTTREE"
printf '1.2.3\n' > "$ARTTREE/VERSION"
cat > "$ARTTREE/install-widget.sh" <<'WIDGET'
#!/usr/bin/env bash
set -euo pipefail
: "${WIDGET_INSTALL_SOURCE:?}"
: "${WIDGET_INSTALLED_FROM:?}"
printf 'source=%s\nprovenance=%s\n' \
  "$WIDGET_INSTALL_SOURCE" "$WIDGET_INSTALLED_FROM" > "$WIDGET_OUTPUT"
WIDGET
chmod +x "$ARTTREE/install-widget.sh"

check "self-installer: builder is valid bash" 0 "" bash -n "$MAKE_INSTALLER"
for product_arg in --name --version --root --out --entrypoint --srcvar; do
  check "self-installer: help names $product_arg" 0 "$product_arg" \
    "$MAKE_INSTALLER" --help
done
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
check "self-installer: help carries no rig-specific product fact" 1 "" \
  bash -c '"$1" --help | grep -qi rig' _ "$MAKE_INSTALLER"
check "self-installer: builds a differently named throwaway tree" 0 \
  "make-installer: wrote $ARTIFACT" \
  "$MAKE_INSTALLER" --name widget --version 1.2.3 --root "$ARTTREE" \
  --out "$ARTIFACT" --entrypoint install-widget.sh
check "self-installer: generated artifact is executable" 0 "" test -x "$ARTIFACT"
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
check "self-installer: widget stub carries no rig string" 1 "" \
  bash -c 'sed "/^__SELF_INSTALLER_PAYLOAD__$/q" "$1" | grep -qi rig' _ "$ARTIFACT"
check "self-installer: --version identifies without installing" 0 "widget 1.2.3" \
  env WIDGET_OUTPUT="$ARTLOG" bash "$ARTIFACT" --version
check "self-installer: --version touches no install output" 1 "" test -e "$ARTLOG"
check "self-installer: --check verifies without installing" 0 "payload intact" \
  env WIDGET_OUTPUT="$ARTLOG" bash "$ARTIFACT" --check
check "self-installer: --check touches no install output" 1 "" test -e "$ARTLOG"
check "self-installer: artifact installs the throwaway tree" 0 "installing widget 1.2.3" \
  env WIDGET_OUTPUT="$ARTLOG" bash "$ARTIFACT"
check "self-installer: source variable is derived from product name" 0 "source=" \
  grep -F 'source=' "$ARTLOG"
check "self-installer: provenance variable is derived from product name" 0 \
  "provenance=artifact:widget-1.2.3.sh sha256:" \
  grep -F 'provenance=artifact:widget-1.2.3.sh sha256:' "$ARTLOG"

ARTSIZE="$(wc -c < "$ARTIFACT" | tr -d ' ')"
TRUNCATED="$ARTWORK/widget-truncated.sh"
head -c "$((ARTSIZE - 1))" "$ARTIFACT" > "$TRUNCATED"
chmod +x "$TRUNCATED"
rm -f "$ARTLOG"
ARTTMP="$ARTWORK/exec-tmp"
mkdir -p "$ARTTMP"
check "self-installer: truncated payload is refused by --check" 1 \
  "payload checksum MISMATCH" env TMPDIR="$ARTTMP" WIDGET_OUTPUT="$ARTLOG" \
  bash "$TRUNCATED" --check
check "self-installer: truncated install is refused before unpacking" 1 \
  "payload checksum MISMATCH" env TMPDIR="$ARTTMP" WIDGET_OUTPUT="$ARTLOG" \
  bash "$TRUNCATED"
check "self-installer: refusal runs no entrypoint" 1 "" test -e "$ARTLOG"
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
check "self-installer: refusal unpacks nothing" 1 "" \
  bash -c 'find "$1" -mindepth 1 -print -quit | grep -q .' _ "$ARTTMP"

# --- rig release artifact (#219) --------------------------------------------
PIN="$(sed -n 's/^RIG_TEMPLATES_PIN=//p' "$ROOT/commands/lib/templates.sh")"
REGISTRY_STAGE="$WORK/registry-stage/rig-templates-$PIN/test-box"
REGISTRY_TARBALL="$WORK/registry.tar.gz"
mkdir -p "$REGISTRY_STAGE"
printf 'USER="artifact-test"\n' > "$REGISTRY_STAGE/template.env"
tar -czf "$REGISTRY_TARBALL" -C "$WORK/registry-stage" "rig-templates-$PIN"

REL_ASSETS="$WORK/release-assets"
mkdir -p "$REL_ASSETS"
check "release artifact: builds rig installer and sidecar with stubbed registry fetch" 0 \
  "release-artifact: wrote" \
  env PATH="$STUB:$PATH" CURL_STUB_OK="$PIN" CURL_STUB_TARBALL="$REGISTRY_TARBALL" \
  "$ROOT/dist/release-artifact.sh" --version 0.0.0-test --assets-dir "$REL_ASSETS"
RIG_ARTIFACT="$REL_ASSETS/rig-0.0.0-test.sh"
check "release artifact: installer exists and is executable" 0 "" test -x "$RIG_ARTIFACT"
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
check "release artifact: sidecar verifies" 0 "rig-0.0.0-test.sh: OK" \
  bash -c 'cd "$1" && sha256sum -c rig-0.0.0-test.sh.sha256' _ "$REL_ASSETS"
CHECK_DEST="$WORK/check-only-dest"
check "release artifact: --check verifies without installing" 0 "payload intact" \
  env RIG_HOME="$CHECK_DEST" bash "$RIG_ARTIFACT" --check
check "release artifact: --check leaves no install root" 1 "" test -e "$CHECK_DEST"
check "release artifact: --version identifies without installing" 0 "rig 0.0.0-test" \
  env RIG_HOME="$CHECK_DEST" bash "$RIG_ARTIFACT" --version
check "release artifact: --version still leaves no install root" 1 "" test -e "$CHECK_DEST"

ART_HOME="$WORK/artifact-home"; ART_BIN="$WORK/artifact-bin"; ART_CURL="$WORK/artifact-curl.log"
artifact_install() {
  env PATH="$STUB:$PATH" HOME="$FAKEHOME" RIG_HOME="$ART_HOME" RIG_BIN="$ART_BIN" \
    RIG_ROLE_MARKER="$WORK/no-marker" CURL_STUB_LOG="$ART_CURL" \
    bash "$RIG_ARTIFACT" > "$WORK/artifact-install.log" 2>&1
}
check "release artifact: installs with no destination-time network" 0 "" artifact_install
INSTALLED_VER="$(cat "$ROOT/VERSION")"
check "release artifact: carries the pinned template registry" 0 "" \
  test -f "$ART_HOME/versions/$INSTALLED_VER/templates@$PIN/test-box/template.env"
check "release artifact: install consulted no curl" 1 "" test -s "$ART_CURL"
check "release artifact: install emitted no snapshot-download warning" 1 "" \
  grep -qF "snapshot skipped" "$WORK/artifact-install.log"
PAYLOAD_SHA="$(bash "$RIG_ARTIFACT" --version | sed -n 's/^payload sha256: //p')"
check "release artifact: durable provenance replaces the temp path" 0 \
  "artifact:rig-0.0.0-test.sh sha256:$PAYLOAD_SHA" \
  cat "$ART_HOME/versions/$INSTALLED_VER/INSTALLED_FROM"
check "release artifact: installed tree names the clean source commit" 0 \
  "$(git -C "$ROOT" rev-parse HEAD)" \
  cat "$ART_HOME/versions/$INSTALLED_VER/SOURCE_COMMIT"

# Build from a disposable dirty Git work tree so this suite never mutates the
# checkout it is running from. The payload remains HEAD, while the stamp names
# that the requested source work tree was dirty.
DIRTY_ROOT="$WORK/dirty-root"
mkdir -p "$DIRTY_ROOT"
git -C "$ROOT" archive HEAD | tar -xf - -C "$DIRTY_ROOT"
git -C "$DIRTY_ROOT" init -q
git -C "$DIRTY_ROOT" config user.name artifact-test
git -C "$DIRTY_ROOT" config user.email artifact-test@example.invalid
git -C "$DIRTY_ROOT" add .
git -C "$DIRTY_ROOT" commit -qm fixture
DIRTY_SHA="$(git -C "$DIRTY_ROOT" rev-parse HEAD)"
mkdir -p "$DIRTY_ROOT/.ceremony-src"
touch "$DIRTY_ROOT/.ceremony-src/release-job-state"
CEREMONY_ASSETS="$WORK/ceremony-assets"; mkdir -p "$CEREMONY_ASSETS"
check "release artifact: ceremony's checkout is not product dirtiness" 0 \
  "release-artifact: wrote" \
  env PATH="$STUB:$PATH" CURL_STUB_OK="$PIN" CURL_STUB_TARBALL="$REGISTRY_TARBALL" \
  "$DIRTY_ROOT/dist/release-artifact.sh" --version ceremony-test \
  --root "$DIRTY_ROOT" --assets-dir "$CEREMONY_ASSETS"
CEREMONY_HOME="$WORK/ceremony-home"; CEREMONY_BIN="$WORK/ceremony-bin"
check "release artifact: ceremony-checkout artifact installs" 0 "done" \
  env PATH="$STUB:$PATH" HOME="$FAKEHOME" RIG_HOME="$CEREMONY_HOME" RIG_BIN="$CEREMONY_BIN" \
  RIG_ROLE_MARKER="$WORK/no-marker" bash "$CEREMONY_ASSETS/rig-ceremony-test.sh"
check "release artifact: ceremony-checkout artifact keeps a clean source stamp" 0 "$DIRTY_SHA" \
  cat "$CEREMONY_HOME/versions/$INSTALLED_VER/SOURCE_COMMIT"
touch "$DIRTY_ROOT/uncommitted-probe"
DIRTY_ASSETS="$WORK/dirty-assets"; mkdir -p "$DIRTY_ASSETS"
check "release artifact: builds from a dirty work tree" 0 "release-artifact: wrote" \
  env PATH="$STUB:$PATH" CURL_STUB_OK="$PIN" CURL_STUB_TARBALL="$REGISTRY_TARBALL" \
  "$DIRTY_ROOT/dist/release-artifact.sh" --version dirty-test \
  --root "$DIRTY_ROOT" --assets-dir "$DIRTY_ASSETS"
DIRTY_HOME="$WORK/dirty-home"; DIRTY_BIN="$WORK/dirty-bin"
check "release artifact: dirty artifact installs" 0 "done" \
  env PATH="$STUB:$PATH" HOME="$FAKEHOME" RIG_HOME="$DIRTY_HOME" RIG_BIN="$DIRTY_BIN" \
  RIG_ROLE_MARKER="$WORK/no-marker" bash "$DIRTY_ASSETS/rig-dirty-test.sh"
check "release artifact: installed tree stamps the source as dirty" 0 "$DIRTY_SHA-dirty" \
  cat "$DIRTY_HOME/versions/$INSTALLED_VER/SOURCE_COMMIT"

# A registry fetch failure must leave no plausible-but-incomplete release asset.
FAIL_ASSETS="$WORK/fail-assets"; mkdir -p "$FAIL_ASSETS"
check "release artifact: registry fetch failure is loud" 1 \
  "could not fetch template registry snapshot" \
  env PATH="$STUB:$PATH" CURL_STUB_FAIL=1 \
  "$ROOT/dist/release-artifact.sh" --version fail-test --assets-dir "$FAIL_ASSETS"
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
check "release artifact: failed build publishes nothing" 1 "" \
  bash -c 'find "$1" -mindepth 1 -print -quit | grep -q .' _ "$FAIL_ASSETS"

rm -rf "$WORK"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
