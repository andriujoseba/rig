#!/usr/bin/env bash
# rig template-lint <role-dir>... — is this a valid role definition?
#
# rig defines what a valid template is (the schema lives in
# lib/templates.sh, beside the mint-time parser that enforces it); the
# heavy-duty/rig-templates repo's CI runs this on every definition on every
# PR, so a broken definition is refused before it can ever reach a mint
# (#110). The two gates are deliberate: CI protects the registry, the
# mint-time parse protects a mint served through RIG_TEMPLATES_REPO/_DIR
# that CI never saw.
#
# Pure read: no root, no network, no writes — lintable anywhere, including
# the registry repo's checkout, where rig's tree is only a fetched tool.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/templates.sh
. "$HERE/lib/templates.sh"   # template_lint (and the schema it enforces)

die() { printf 'rig-template-lint: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig template-lint <role-dir>...

Validate role definitions (the heavy-duty/rig-templates shape).

Tenant roles use a *-box directory, tenant template.env schema, a shebang
install.sh, and non-blank creds.md. Machine roles use a *-server directory
(or exact name workstation), the ROOT_DOOR/HOST/JOIN schema, no creds.md,
and an optional install.sh which must be non-empty and carry a shebang.
template.env is parsed as KEY="value" data and never sourced. Every refusal
names the failing key or file. Exits non-zero if any definition fails;
nothing is written.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; die "at least one role directory required" 2 ;;
esac

fail=0
for dir in "$@"; do
  case "$dir" in
    -*) usage >&2; die "unknown flag: $dir" 2 ;;
  esac
  if template_lint "$dir"; then
    printf 'rig-template-lint: OK: %s\n' "$dir"
  else
    printf 'rig-template-lint: FAIL: %s\n' "$dir" >&2
    fail=1
  fi
done
exit "$fail"
