#!/usr/bin/env bash
set -euo pipefail
# dist/release-artifact.sh — build rig's offline release asset and checksum.
# Copied from heavy-duty/box@bb39772374c4cc8764794a65f92292edd5880df4:
# dist/release-artifact.sh, with rig's product and template-registry facts.
#
# The release hook runs after the tag exists and before GitHub publishes the
# release. A non-zero exit therefore leaves the tag created and no release
# published. Recover by fixing the cause, then deleting and re-pushing the same
# tag so both release doors see the corrected tree (#219).

usage() {
  cat <<'USAGE'
release-artifact.sh — build rig's release installer and checksum
  --version VER       release version                              [required]
  --root DIR          rig tree to pack                    [default: repo root]
  --assets-dir DIR    output directory       [default: $RELEASE_ASSETS_DIR]
USAGE
}

die() { printf 'release-artifact: ERROR: %s\n' "$*" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version=''
root="$(cd "$script_dir/.." && pwd)"
assets_dir="${RELEASE_ASSETS_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --version)    version="${2:?--version needs a value}"; shift 2 ;;
    --root)       root="${2:?--root needs a value}"; shift 2 ;;
    --assets-dir) assets_dir="${2:?--assets-dir needs a value}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument '$1' (see --help)" ;;
  esac
done

[ -n "$version" ] || die "--version is required"
[ -n "$assets_dir" ] || die "--assets-dir or RELEASE_ASSETS_DIR is required"
[ -d "$root" ] || die "--root '$root' is not a directory"
root="$(cd "$root" && pwd)"
mkdir -p "$assets_dir"
assets_dir="$(cd "$assets_dir" && pwd)"

artifact="rig-$version.sh"
sidecar="$artifact.sha256"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tree" "$work/assets" "$work/templates-unpack"

# A release checkout may contain ceremony's own checkout in .ceremony-src and
# other job state. When --root is a Git work tree, HEAD is the release payload;
# never pack the mutable workspace around it. The stamp still says when that
# workspace was dirty, because a hand-built drill artifact must be honest about
# the checkout state from which it was requested. Ceremony's own untracked
# checkout is release machinery rather than product dirtiness and is excluded.
source_commit=unknown
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  top="$(git -C "$root" rev-parse --show-toplevel)"
  [ "$(cd "$top" && pwd)" = "$root" ] || die "--root must name the Git work-tree root"
  source_commit="$(git -C "$root" rev-parse HEAD)"
  if [ -n "$(git -C "$root" status --porcelain --untracked-files=normal -- . ':(exclude).ceremony-src')" ]; then
    source_commit="$source_commit-dirty"
  fi
  git -C "$root" archive --format=tar HEAD | tar -xf - -C "$work/tree"
else
  tar -C "$root" --exclude=.git -cf - . | tar -xf - -C "$work/tree"
  if [ -s "$work/tree/SOURCE_COMMIT" ]; then
    source_commit="$(head -n1 "$work/tree/SOURCE_COMMIT")"
  fi
fi
printf '%s\n' "$source_commit" > "$work/tree/SOURCE_COMMIT"

[ -x "$work/tree/dist/make-installer.sh" ] \
  || die "--root is not a rig tree: dist/make-installer.sh is missing or not executable"

# An offline rig is incomplete without the exact template registry its pin
# names. Fetch it while building, fail closed, and pack it at the same path the
# installer would otherwise create on the destination machine.
pin="$(sed -n 's/^RIG_TEMPLATES_PIN=//p' "$work/tree/commands/lib/templates.sh" 2>/dev/null | head -n1 || true)"
[ -n "$pin" ] || die "the rig tree carries no RIG_TEMPLATES_PIN"
repo="${RIG_TEMPLATES_REPO:-heavy-duty/rig-templates}"
got=''
for url in \
  "https://github.com/$repo/archive/refs/tags/$pin.tar.gz" \
  "https://github.com/$repo/archive/refs/heads/$pin.tar.gz" \
  "https://github.com/$repo/archive/$pin.tar.gz"; do
  if curl -fsSL "$url" -o "$work/templates.tar.gz" 2>/dev/null; then
    got="$url"
    break
  fi
done
[ -n "$got" ] || die "could not fetch template registry snapshot $repo@$pin"
tar -xzf "$work/templates.tar.gz" -C "$work/templates-unpack" \
  || die "could not extract template registry snapshot from $got"
set -- "$work/templates-unpack"/*/
{ [ $# -eq 1 ] && [ -d "$1" ]; } \
  || die "template registry snapshot from $got has an unexpected archive shape"
template_root="${1%/}"
[ -n "$(find "$template_root" -mindepth 2 -maxdepth 2 -type f -name template.env -print -quit)" ] \
  || die "template registry snapshot from $got has no definitions"
rm -rf "$work/tree/templates@$pin"
mv "$template_root" "$work/tree/templates@$pin"

"$work/tree/dist/make-installer.sh" \
  --name rig \
  --version "$version" \
  --root "$work/tree" \
  --out "$work/assets/$artifact" \
  --entrypoint install.sh \
  --srcvar RIG_INSTALL_SOURCE

# Prove the finished installer before either release asset becomes visible.
[ -s "$work/assets/$artifact" ] \
  || die "the installer build left no usable artifact"
bash "$work/assets/$artifact" --check
(
  cd "$work/assets"
  sha256sum "$artifact" > "$sidecar"
  sha256sum -c "$sidecar"
)

[ ! -e "$assets_dir/$artifact" ] || die "$assets_dir/$artifact already exists"
[ ! -e "$assets_dir/$sidecar" ] || die "$assets_dir/$sidecar already exists"
mv "$work/assets/$artifact" "$work/assets/$sidecar" "$assets_dir/"
printf 'release-artifact: wrote %s and %s\n' \
  "$assets_dir/$artifact" "$assets_dir/$sidecar"
