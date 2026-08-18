#!/usr/bin/env bash
# rig runner install — GitHub Actions self-hosted runner as a systemd service
# under an unprivileged user. Outbound-only (long-poll to GitHub), no Docker.
# Convergent toward --repo, PER INSTANCE (#166): re-running against the repo
# that instance is already on leaves it alone; an instance registered to a
# DIFFERENT repo is refused, never silently restarted on the old one (that is
# `repoint`'s job). A box runs any number of instances, keyed by --name.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/runner-config.sh
. "$HERE/lib/runner-config.sh"

log()  { printf 'rig-runner: %s\n' "$*"; }
warn() { printf 'rig-runner: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner install --repo <owner/repo> [options]

  --repo <owner/repo>   GitHub repository the runner registers to (required)
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

Provide the short-lived registration token via the RUNNER_TOKEN env var or
the interactive prompt (get one from the repo's Settings > Actions >
Runners > "New self-hosted runner", or:
  gh api -X POST repos/<owner/repo>/actions/runners/registration-token).
It is consumed at registration and never written to disk by rig.

INSTANCES. Each instance gets its own directory (~/actions-runner/<name>),
its own _work and its own systemd unit; the service user is shared unless
--user says otherwise. Four runners on one box is four installs, one per
name. Boxes installed before instances existed keep the directory and the
unit they have: omit --name there and rig converges that runner in place.

Convergent toward --repo, per instance: re-running against the repo that
instance is already on re-uses the binary, skips registration, and never
asks for a token. An instance registered to a DIFFERENT repo is refused —
moving one is `rig runner repoint --repo <owner/repo> --name <name>`, and
running a SECOND runner beside it is this command with a new --name.

A name already taken by a runner rig did not create is refused rather than
re-registered: config.sh --replace would deregister that runner.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
REPO=""
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
[ -n "$REPO" ] || die "--repo <owner/repo> is required" 2
if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  die "--repo must be owner/repo" 2
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
  local instances line
  BASE_DIR="$(runner_base_dir "$USER_HOME")"
  instances="$(runner_scan_units | runner_merge_instances "$BASE_DIR")"

  # The one rule that reads the box rather than the name, and the whole of the
  # migration: a box whose runner lives in the legacy <base> layout keeps it.
  # Omitting --name there means "the runner this box already has", whatever it
  # is called — which is exactly what omitting it meant before instances
  # existed, so such a box converges with the same dir, the same unit and no
  # re-registration. Pass a name and you get an instance, including beside
  # that one.
  if [ "$NAME_GIVEN" -eq 0 ] && runner_is_instance_dir "$BASE_DIR"; then
    RUNNER_DIR="$BASE_DIR"
    RUNNER_NAME="$(runner_instance_name "$BASE_DIR")"
    return 0
  fi

  if line="$(runner_pick "$RUNNER_NAME" "$instances")"; then
    if [ "$(printf '%s\n' "$line" | grep -c .)" -ne 1 ]; then
      die "more than one runner on this box answers to '${RUNNER_NAME}':
$(runner_candidates "$line")
rig will not guess which one you meant."
    fi
    # An unmanaged instance is someone's hand-rolled runner. Registering over
    # its name is not convergence: config.sh --replace would deregister it and
    # rig would report success, which is the class of bug #166 is about.
    if [ "$(printf '%s' "$line" | cut -f4)" = "unmanaged" ]; then
      die "the name '${RUNNER_NAME}' is taken by a runner rig did not create:
$(runner_candidates "$line")
registering over it would deregister that runner (config.sh --replace).
Pick another --name, or take that one down first."
    fi
    RUNNER_DIR="$(printf '%s' "$line" | cut -f2)"
    return 0
  fi

  # A new instance. Refusing an occupied path is what keeps a name out of the
  # tarball's own top-level entries (bin/, externals/, config.sh) on a box
  # carrying the legacy layout, with no reserved-word list to keep in sync.
  RUNNER_DIR="$BASE_DIR/$RUNNER_NAME"
  if [ -e "$RUNNER_DIR" ] && ! runner_is_instance_dir "$RUNNER_DIR"; then
    die "${RUNNER_DIR} exists and is not a runner install — choose another --name"
  fi
  return 0
}

# Registration is pending unless the runner user already exists AND the
# resolved instance has a .runner (user absent => nothing can be registered).
REG_PENDING=1
if id -u "$RUNNER_USER" >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
  resolve_instance
  assert_runner_repo "$RUNNER_DIR" "$REPO" "$RUNNER_NAME" || exit 1
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
  log "registering runner ${RUNNER_NAME} against ${REPO}"
  (cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- env HOME="$USER_HOME" \
    ./config.sh --url "https://github.com/${REPO}" --token "$RUNNER_TOKEN" \
    --name "$RUNNER_NAME" --labels "$LABELS" --unattended --replace)
  # GitHub owns the labels and the runner does not persist them locally, so
  # `runner status` and `runner repoint` would have nothing to read. Record
  # what we registered with — box-local metadata, never a credential.
  printf '%s\n' "$LABELS" > "$RUNNER_DIR/.rig-labels"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/.rig-labels"
fi

# Written whether or not this run registered anything: the name is what every
# selector resolves against, and it must outlive the registration. `remove`
# deletes .runner and .rig-labels and keeps the binary, so without this an
# instance would lose its identity the moment it was removed — and `install`
# would then build a sibling beside the directory it should have re-used.
if [ ! -r "$RUNNER_DIR/.rig-instance" ] \
  || [ "$(head -n1 "$RUNNER_DIR/.rig-instance")" != "$RUNNER_NAME" ]; then
  printf '%s\n' "$RUNNER_NAME" > "$RUNNER_DIR/.rig-instance"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/.rig-instance"
fi

# --- service -------------------------------------------------------------
if [ ! -e "$RUNNER_DIR/.service" ]; then
  (cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER")
fi
(cd "$RUNNER_DIR" && ./svc.sh start)

log "runner ${RUNNER_NAME} (labels: ${LABELS}) installed and running at ${RUNNER_DIR}"
log "every runner on this box: rig runner status"
log "verify it shows Idle under the repo's Settings > Actions > Runners"
log "the deny-all provider firewall stays the operator's job outside rig — this box needs no inbound ports for the runner"
