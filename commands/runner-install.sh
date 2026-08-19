#!/usr/bin/env bash
# rig runner install — GitHub Actions self-hosted runner as a systemd service
# under an unprivileged user. Outbound-only (long-poll to GitHub), no Docker.
# Convergent toward one repository or organization target, PER INSTANCE
# (#165, #166). A scope or target change is refused here and belongs to
# `repoint`; widening repo access to an organization is a trust-boundary act.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/runner-config.sh
. "$HERE/lib/runner-config.sh"

log()  { printf 'rig-runner: %s\n' "$*"; }
warn() { printf 'rig-runner: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner install (--repo <owner/repo> | --org <org>) [options]

  --repo <owner/repo>   register this instance to one GitHub repository
  --org <org>           register this instance to a GitHub organization
  --runnergroup <name>  organization runner group (default: Default)
  --version <pin>       actions/runner release to install, e.g. 2.335.1
                        (default: the latest release, resolved at install
                        time — safe here because the runner self-updates
                        regardless; pin it when you need a deterministic,
                        auditable install)
  --name <name>         runner instance to create or converge (default: this
                        host's hostname). The name is the key: a box runs as
                        many instances as you give it names
  --labels <csv>        runner labels; replaces the default (default: ci-runner)
  --user <name>         unprivileged service user (default: github-runner;
                        created if absent; never root)

Installs GitHub's official actions/runner as a systemd service under an
unprivileged user. The runner is an agent, not a server: it long-polls
GitHub outbound and needs ZERO inbound ports. No Docker is installed and
the runner user gets no supplementary groups.

Exactly one of --repo and --org is required. Provide the short-lived
registration token via RUNNER_TOKEN or the interactive prompt (or mint it):
  gh api -X POST repos/<owner/repo>/actions/runners/registration-token
  gh api -X POST orgs/<org>/actions/runners/registration-token
It is consumed at registration and never written to disk by rig.

INSTANCES. Each instance gets its own directory (~/actions-runner/<name>),
its own _work and its own systemd unit; the service user is shared unless
--user says otherwise. Four runners on one box is four installs, one per
name. Boxes installed before instances existed keep the directory and the
unit they have: omit --name there and rig converges that runner in place.

Convergent toward one scope and target, per instance: re-running against the
repository or organization that instance is already on re-uses the binary,
skips registration, and never asks for a token. A different target or a
repo↔organization scope change is refused — moving one is `rig runner
repoint`, and running a SECOND runner beside it is this command with a new
--name.

A name already taken by a runner rig did not create is refused rather than
re-registered: config.sh --replace would deregister that runner. So is a
name whose directory holds a runner answering to something else — a
hand-rolled install, or one `repoint --rename` moved the identity of:
installing there would adopt that runner, not create this one.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
REPO=""
ORG=""
RUNNER_GROUP="Default"
VERSION=""
RUNNER_NAME="$(hostname)"
NAME_GIVEN=0
LABELS="ci-runner"
RUNNER_USER="github-runner"
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
      RUNNER_GROUP="$2"; shift 2 ;;
    --version)
      [ $# -ge 2 ] || die "--version needs a value" 2
      VERSION="$2"; shift 2 ;;
    --name)
      [ $# -ge 2 ] || die "--name needs a value" 2
      RUNNER_NAME="$2"; NAME_GIVEN=1; shift 2 ;;
    --labels)
      [ $# -ge 2 ] || die "--labels needs a value" 2
      LABELS="$2"; shift 2 ;;
    --user)
      [ $# -ge 2 ] || die "--user needs a value" 2
      RUNNER_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- validation ----------------------------------------------------------
[ -z "$REPO" ] || [ -z "$ORG" ] || die "--repo and --org are mutually exclusive" 2
[ -n "$REPO" ] || [ -n "$ORG" ] || die "exactly one of --repo <owner/repo> or --org <org> is required" 2
if [ -n "$REPO" ] && ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  die "--repo must be owner/repo" 2
fi
if [ -n "$ORG" ] && ! printf '%s' "$ORG" | grep -qE '^[A-Za-z0-9_.-]+$'; then
  die "--org must be an organization name" 2
fi
if [ -n "$REPO" ] && [ "$RUNNER_GROUP" != "Default" ]; then
  die "--runnergroup is only valid with --org" 2
fi
[ -n "$RUNNER_GROUP" ] || die "--runnergroup must not be empty" 2
case "${RUNNER_GROUP}${LABELS}" in
  *$'\n'*|*$'\r'*) die "--runnergroup and --labels must each be one line" 2 ;;
esac
if [ -n "$ORG" ]; then
  SCOPE="org"; TARGET="$ORG"
else
  SCOPE="repo"; TARGET="$REPO"; RUNNER_GROUP=""
fi
VERSION="${VERSION#v}"
[ "$RUNNER_USER" != "root" ] || die "runner user must not be root" 2
# The instance name becomes a directory under the base, so it is a path
# component and nothing more: no slash, no `..`, no leading dot. The hostname
# default is validated too — every RFC 1123 hostname passes, and one that does
# not (an empty `hostname` in a broken container) must refuse here rather than
# unpack a runner into a directory with no name.
if ! runner_valid_name "$RUNNER_NAME"; then
  if [ "$NAME_GIVEN" -eq 1 ]; then
    die "--name must be letters, digits, dot, underscore or dash, and start with a letter or digit: '${RUNNER_NAME}'" 2
  fi
  die "this host's name ('${RUNNER_NAME}') cannot be an instance name — pass --name <name>" 2
fi

# --- guards ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
if [ -r /etc/os-release ]; then
  # Sourced in a subshell: os-release defines VERSION (e.g. "13 (trixie)"),
  # which would clobber this script's $VERSION.
  # shellcheck source=/dev/null
  OS_FAMILY="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  case "$OS_FAMILY" in
    *debian*) ;;
    *) warn "not a Debian-family system (${OS_FAMILY:-unknown}); proceeding anyway" ;;
  esac
else
  warn "cannot read /etc/os-release; proceeding anyway"
fi
command -v curl >/dev/null || die "curl is required (run rig bootstrap first)"

# --- which instance is this, and is it already registered elsewhere? ----------
# Before anything is prompted for, downloaded, or started: the instance --name
# selects must agree with --repo. Everything below this point treats an
# existing .runner as "nothing to do" — which is right for the repo that
# instance is already on, and silently wrong for any other. See
# assert_runner_repo.
#
# resolve_instance sets RUNNER_DIR, and may correct RUNNER_NAME when it adopts
# a legacy install. It needs USER_HOME, so it runs once here when the user is
# already present (the guard has to precede the token prompt) and once after
# the user is created on a fresh box.
BASE_DIR=""
RUNNER_DIR=""
resolve_instance() {
  local resolved
  BASE_DIR="$(runner_base_dir "$USER_HOME")"
  resolved="$(runner_resolve_instance "$BASE_DIR" "$RUNNER_NAME" "$NAME_GIVEN" \
    "$(runner_scan_units | runner_merge_instances "$BASE_DIR")")" || exit 1
  RUNNER_DIR="$(printf '%s' "$resolved" | cut -f1)"
  RUNNER_NAME="$(printf '%s' "$resolved" | cut -f2)"
}

# Registration is pending unless the runner user already exists AND the
# resolved instance has a .runner (user absent => nothing can be registered).
REG_PENDING=1
if id -u "$RUNNER_USER" >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
  resolve_instance
  if [ "$SCOPE" = "repo" ]; then
    assert_runner_repo "$RUNNER_DIR" "$TARGET" "$RUNNER_NAME" || exit 1
  else
    assert_runner_target "$RUNNER_DIR" "$SCOPE" "$TARGET" "$RUNNER_GROUP" "$RUNNER_NAME" || exit 1
  fi
  if [ -e "$RUNNER_DIR/.runner" ]; then
    REG_PENDING=0
  fi
fi

# --- registration token — only when registration is actually pending -------
if [ "$REG_PENDING" -eq 1 ]; then
  RUNNER_TOKEN="${RUNNER_TOKEN:-}"
  # Prompt only on a tty: headless, a bare `read` dies under set -e with no
  # message at all (drill-measured). Refuse loudly, naming the variable.
  if [ -z "$RUNNER_TOKEN" ]; then
    [ -t 0 ] || die "RUNNER_TOKEN is unset and stdin is not a tty — set RUNNER_TOKEN to run unattended"
    read -rsp "runner registration token (short-lived): " RUNNER_TOKEN || { echo; die "no registration token read (EOF) — set RUNNER_TOKEN to run unattended"; }
    echo
  fi
  [ -n "$RUNNER_TOKEN" ] || die "empty registration token"
fi

# --- user --------------------------------------------------------------------
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$RUNNER_USER"
  log "created user ${RUNNER_USER}"
  USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
  resolve_instance
else
  log "user exists"
fi
log "instance ${RUNNER_NAME} at ${RUNNER_DIR}"

# The base carries the sibling instances, so it is the runner user's too. On a
# box in the legacy layout BASE_DIR and RUNNER_DIR are the same directory and
# this is the chown that was always here.
mkdir -p "$RUNNER_DIR"
chown "$RUNNER_USER:$RUNNER_USER" "$BASE_DIR" "$RUNNER_DIR"

# The mark of rig's ownership goes down HERE, with the directory rig just
# claimed — before the download and before config.sh, not after them.
#
# Two reasons, and the second is why it moved (#174 round 1). The name is what
# every selector resolves against and it must outlive the registration:
# `remove` deletes .runner and .rig-labels and keeps the binary, so without
# this an instance would lose its identity the moment it was removed, and
# `install` would build a sibling beside the directory it should have re-used.
# And since `managed` now means "rig put this here" rather than "this sits
# under the base", writing the marker only on the way OUT would leave every
# install that died in between — a download that 404s on a pinned version, a
# config.sh that fails on an expired token — owning a directory rig would
# refuse to touch again as somebody else's hand-rolled runner. Claiming the
# directory and marking it are the same act, so they happen together.
#
# The legacy base is adopted in place and carries no marker by definition, so
# the first converge run after this lands DOES write one — and writes the right
# thing: RUNNER_NAME there is the name that box already answered to, resolved
# from its own `.runner` (or the hostname default when it never registered),
# never the directory. Adoption is what the write records; the guard skips only
# the re-write on every converge after it.
if [ ! -r "$RUNNER_DIR/.rig-instance" ] \
  || [ "$(head -n1 "$RUNNER_DIR/.rig-instance")" != "$RUNNER_NAME" ]; then
  printf '%s\n' "$RUNNER_NAME" > "$RUNNER_DIR/.rig-instance"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/.rig-instance"
fi

# --- download + unpack ------------------------------------------------------
if [ -e "$RUNNER_DIR/bin/Runner.Listener" ]; then
  log "runner binary already present; skipping download (self-update owns upgrades)"
else
  case "$(uname -m)" in
    x86_64) ARCH="x64" ;;
    aarch64) ARCH="arm64" ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
  if [ -z "$VERSION" ]; then
    # No pin given: resolve the latest release by following the redirect on
    # the /releases/latest page — no API call, no rate limit, no JSON to
    # parse on a dependency-free box.
    LATEST_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://github.com/actions/runner/releases/latest)" \
      || die "could not resolve the latest actions/runner release"
    VERSION="${LATEST_URL##*/}"
    VERSION="${VERSION#v}"
    case "$VERSION" in
      ""|*[!0-9.]*) die "could not parse a version from ${LATEST_URL}" ;;
    esac
    log "resolved latest actions/runner: ${VERSION}"
  fi
  URL="https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-${ARCH}-${VERSION}.tar.gz"
  WORKDIR="$(mktemp -d)"
  cleanup() { rm -rf "$WORKDIR"; }
  trap cleanup EXIT
  log "downloading actions/runner ${VERSION} (${ARCH})"
  curl -fsSL "$URL" -o "$WORKDIR/runner.tar.gz"
  tar xzf "$WORKDIR/runner.tar.gz" -C "$RUNNER_DIR"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
  log "installing runner native dependencies"
  "$RUNNER_DIR"/bin/installdependencies.sh
fi

# --- configure ---------------------------------------------------------------
if [ -e "$RUNNER_DIR/.runner" ]; then
  log "already registered; skipping configure"
else
  log "registering runner ${RUNNER_NAME} against ${SCOPE} ${TARGET}"
  CONFIG_ARGS=(--url "https://github.com/${TARGET}" --token "$RUNNER_TOKEN"
    --name "$RUNNER_NAME" --labels "$LABELS" --unattended --replace)
  [ "$SCOPE" != "org" ] || CONFIG_ARGS+=(--runnergroup "$RUNNER_GROUP")
  (cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- env HOME="$USER_HOME" \
    ./config.sh "${CONFIG_ARGS[@]}")
  # GitHub owns the labels and the runner does not persist them locally, so
  # `runner status` and `runner repoint` would have nothing to read. Record
  # what we registered with — box-local metadata, never a credential.
  runner_write_record "$RUNNER_DIR" "$SCOPE" "$RUNNER_GROUP" "$LABELS"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/.rig-labels"
fi

# --- service -------------------------------------------------------------
if [ ! -e "$RUNNER_DIR/.service" ]; then
  (cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER")
fi
(cd "$RUNNER_DIR" && ./svc.sh start)

log "runner ${RUNNER_NAME} (labels: ${LABELS}) installed and running at ${RUNNER_DIR}"
log "every runner on this box: rig runner status"
log "verify it shows Idle under the ${SCOPE}'s Settings > Actions > Runners"
log "the deny-all provider firewall stays the operator's job outside rig — this box needs no inbound ports for the runner"
