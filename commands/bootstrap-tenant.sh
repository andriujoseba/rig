#!/usr/bin/env bash
# rig bootstrap <role>-box — the box TENANT roles ('-box' names the family: a
# guest, vs the '-server' machine roles): what a box-minted guest becomes
# (issue #31). box mints the thin, creds-free seed (base image, user, rig
# preinstalled — heavy-duty/box#81); rig converges the tenant content that
# used to live in the templates' cloud-init, idempotent and effective-state
# asserted, so an EXISTING box can be re-run to a new spec instead of
# re-minted.
#
# One MECHANISM, parameterized per tenant by a fetched DEFINITION (#110): the
# agent-tenant registry lives in heavy-duty/rig-templates — one directory per
# role (template.env, install.sh, creds.md), resolved through lib/templates.sh
# (RIG_TEMPLATES_DIR > RIG_TEMPLATES_REF > the in-tree pin) — so adding a
# tenant is a data PR there, never an edit here (#109 is the scar: adding
# kimi, pure data, meant editing six files in this repo). staging-box is the
# one in-tree tenant: it is mechanism-adjacent (sshd hardening, docker — no
# agent, no CLI, no context file), so it converges from rig's own tree.
#
# Creds-free BY CONTRACT: box auto-runs these at mint ('box exec … rig
# bootstrap claude-box'), so every path here is non-interactive and nothing joins
# or admits — no tailnet, no keys, no prompts. That is also why the registry
# fetch is UNAUTHENTICATED: a mint holds nothing to authenticate with.
# staging-box's tailnet join stays operator-run ('rig bootstrap
# workload-server' through 'box shell'), exactly the creds split box#69
# designed.
# Convergent: safe to re-run; a second run changes nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/templates.sh
. "$HERE/lib/templates.sh"       # templates_resolve / template_parse_env / render_tenant_context
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"    # read_role_marker / root_door_of
# shellcheck source=SCRIPTDIR/lib/sshd.sh
. "$HERE/lib/sshd.sh"            # harden_sshd (the staging-box tenant)
# shellcheck source=SCRIPTDIR/lib/manifest.sh
. "$HERE/lib/manifest.sh"        # manifest_stamp — provenance, written beside the marker

log()  { printf 'rig-bootstrap: %s\n' "$*"; }
warn() { printf 'rig-bootstrap: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-bootstrap: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig bootstrap <role>-box [--user <name>]

Box TENANT roles — what a box-minted guest becomes. box mints the thin,
creds-free seed (base image, user, rig preinstalled); this converges the
tenant on top, and re-runs converge an existing box to a new spec.

  <role>-box          an agent tenant DEFINED IN THE REGISTRY
                      (heavy-duty/rig-templates — claude-box, codex-box,
                      grok-box, kimi-box, …): base tooling (git, gh, tmux, …),
                      docker, the agent's CLI on the system PATH, and the
                      agent-context file — including the box#80 guard: never
                      run `box setup-host` or the drill inside a box.
  staging-box         the server tenant (box#69's posture), in rig's own
                      tree: docker + sshd hardening. The tailnet workload
                      join is deliberately NOT here — it holds a credential,
                      so it stays operator-run: `box shell` → `sudo rig
                      bootstrap workload-server` with a tagged pre-auth key.

  --user <name>       the tenant user the box seed created (default: the
                      definition's USER; staging-box defaults to `ops`)

The registry source is three knobs, precedence high to low:
  RIG_TEMPLATES_DIR   a local folder (no fetch — the offline/test path, and
                      "try a template before it exists anywhere")
  RIG_TEMPLATES_REF   a ref of RIG_TEMPLATES_REPO (default
                      heavy-duty/rig-templates), fetched as a tarball
  (neither set)       the ref pinned in rig's tree (lib/templates.sh
                      RIG_TEMPLATES_PIN — bumped by ordinary rig PR, so a
                      rig release freezes the mechanism+registry pair)

Tenant roles are creds-free and non-interactive by contract — box auto-runs
them at mint (`box exec … rig bootstrap claude-box`). They take none of the
machine-role traits (--hostname/--root-door/--host/--join): a tenant is a guest,
not a tailnet machine. Run as root, inside the box.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
ROLE="${1:-}"
case "$ROLE" in
  staging-box) shift ;;
  *-box)
    # The family suffix is the whole gate here — WHICH '-box' roles exist is
    # the resolved registry's fact, checked below, so a template added to the
    # registry is mintable with zero code changes in rig (#110).
    shift ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; die "tenant role required (a '-box' role from the template registry, or staging-box)" 2 ;;
  *) die "unknown tenant role: $ROLE — tenant roles carry the '-box' family suffix (#76); the machine roles are control-plane-server|workload-server|runner-server|staging-server|dev-server|workstation|custom" 2 ;;
esac
# The suffix rule above admits ANY '-box' name, so the charset is pinned
# before the name is ever used as a path component: a crafted role dies HERE,
# never in a registry lookup (the valid_version discipline, bin/rig).
[[ "$ROLE" =~ ^[a-z][a-z0-9-]*-box$ ]] \
  || die "invalid tenant role name: '$ROLE' — must match ^[a-z][a-z0-9-]*-box\$" 2

TENANT_USER_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --user)
      [ $# -ge 2 ] || die "--user needs a value" 2
      TENANT_USER_OVERRIDE="$2"; shift 2
      # Same charset the users file enforces, for the same reasons (a leading
      # '-' reads as a usermod flag; '|', ':' corrupt things downstream).
      # Checked HERE, at parse — the definition's USER is checked by the
      # parser — so the refusal needs no registry and no network.
      [[ "$TENANT_USER_OVERRIDE" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
        || die "invalid user: '$TENANT_USER_OVERRIDE' — must match ^[a-z_][a-z0-9_-]{0,31}\$" 2 ;;
    --hostname|--root-door|--host|--join)
      # The machine-role traits, refused with a story rather than "unknown
      # flag": a tenant is a guest, not a tailnet machine — its shape comes
      # from the box seed, and the one trait-shaped thing a staging-box guest
      # eventually does (join the tailnet as a workload) is deliberately not
      # here: it holds a credential, so it stays operator-run.
      die "tenant roles have no traits: $1 belongs to the machine roles (control-plane-server|workload-server|runner-server|staging-server|dev-server|workstation|custom). A tenant box's shape comes from its seed; staging-box's tailnet join is operator-run via 'rig bootstrap workload-server'. The METAL that hosts these guests is 'rig bootstrap staging-server'." 2 ;;
    --ts-tag)
      [ $# -ge 2 ] && shift
      die "--ts-tag is gone and tenant roles never join the tailnet anyway. staging-box's join is operator-run via 'rig bootstrap workload-server', where the tag comes from the pre-auth key." 2 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- guards ------------------------------------------------------------------
# A tenant role converges a box GUEST. A box already carrying a machine-role
# marker is a tailnet machine rig built on purpose, and quietly turning it into
# a tenant (or clobbering its marker) is how a fleet box gets poisoned. Checked
# BEFORE the root check so the refusals are testable non-root, off fixture
# markers (repo precedent: the coolify marker warning). Two refusals, one
# tolerance:
#   - host=yes  → refuse, every tenant: a VM HOST is the opposite of a guest.
#     Names the staging PAIR out loud, because whoever lands here has the two
#     halves confused: the metal is `staging-server`, the guest `staging-box`.
#   - a root-door policy (agent tenants) → refuse: an agent box is never a
#     tailnet machine.
#   - root-door=open with host=no (staging-box only) → PROCEED, and leave the
#     marker alone: that is the guest AFTER its operator-run workload join, and
#     re-converging docker+hardening on it is exactly what convergence is for.
#     ONLY that shape — any other door policy (say root-door=closed, via
#     `custom`) is a machine rig built on purpose, and staging-box hardening it
#     with open-door rules would die with root-door=open-specific messaging on a
#     box that was never one.
#
# "Names a root-door policy" IS this guard's "is this a machine marker?" test —
# a tenant marker deliberately carries none — so it must be asked through
# root_door_of, which reads the pre-#77 `class=` spelling as well as the current
# `root-door=` one. Pattern-matching the marker for one spelling is what this
# guard used to do, and after the rename that is a fail-OPEN bug in the
# dangerous direction: every box bootstrapped in the OTHER vocabulary stops
# looking like a machine, the refusals below never fire, and a tenant converge
# clobbers a real fleet box's marker. The resolver is the only reader.
MARKER_PATH="${RIG_ROLE_MARKER:-/etc/rig/role}"
EXISTING_MARKER="$(read_role_marker "$MARKER_PATH")"
EXISTING_ROOT_DOOR="$(root_door_of "$EXISTING_MARKER")"
case "$EXISTING_MARKER" in
  *host=yes*)
    die "this box hosts VMs (${EXISTING_MARKER}) — a tenant role converges box GUESTS, never the host under them. You want the other half of the pair: the metal is 'rig bootstrap staging-server', and the guests it mints are 'staging-box'." ;;
esac
if [ -n "$EXISTING_ROOT_DOOR" ]; then
  if [ "$ROLE" != "staging-box" ]; then
    die "this box already carries a machine role (${EXISTING_MARKER}) — the agent tenants converge box guests, never tailnet machines. If this really is a guest, remove ${MARKER_PATH} and re-run."
  fi
  # A `conflict` marker lands here too, and refuses: a box whose two door
  # claims disagree is emphatically not the one shape staging-box tolerates.
  if [ "$EXISTING_ROOT_DOOR" != "open" ]; then
    die "this box carries a machine role whose root door is not open (${EXISTING_MARKER}) — staging-box tolerates only the workload-joined guest (root-door=open host=no, or its pre-#77 spelling class=server). If this really is a staging-box guest, remove ${MARKER_PATH} and re-run."
  fi
fi

# --- the definition ----------------------------------------------------------
# Resolved and parsed BEFORE the root check (but after the marker guards,
# which need no definition and must stay refusable with no registry in
# reach), so the two refusals a definition can earn — unknown role (listing
# what the resolved source actually contains) and malformed data (naming the
# failing key) — are testable non-root, offline, via RIG_TEMPLATES_DIR
# fixtures. The parse is the mint's
# own guard, deliberately duplicating the registry CI's lint: CI protects the
# registry, this protects a mint served through RIG_TEMPLATES_REPO/_DIR that
# CI never saw. template.env is parsed, NEVER sourced — a definition cannot
# execute arbitrary shell through its data file; install.sh is the one
# deliberately executable part, and it runs only after the root check below.
trap '[ -n "$TEMPLATES_TMP" ] && rm -rf "$TEMPLATES_TMP"' EXIT
TPL_DIR=""
if [ "$ROLE" = "staging-box" ]; then
  TENANT_USER="${TENANT_USER_OVERRIDE:-ops}"   # box#69's ops
else
  templates_resolve \
    || die "cannot resolve the template registry ($(templates_source_desc)) — see above" 2
  TPL_DIR="$REGISTRY_DIR/$ROLE"
  if [ ! -f "$TPL_DIR/template.env" ]; then
    die "unknown tenant role: $ROLE — the resolved registry ($(templates_source_desc)) defines: $(templates_roles "$REGISTRY_DIR" | tr '\n' ' ')— and staging-box is in rig's own tree. A misconfigured RIG_TEMPLATES_REPO/_REF/_DIR looks exactly like this; check the source before the spelling." 2
  fi
  template_parse_env "$TPL_DIR/template.env" \
    || die "invalid definition for $ROLE in $(templates_source_desc) — the failing key is named above. The registry's CI lints every PR ('rig template-lint'); a malformed definition reaching a mint means the source above was never linted." 2
  TENANT_USER="${TENANT_USER_OVERRIDE:-$TPL_USER}"
fi

[ "$(id -u)" -eq 0 ] || die "must run as root"
if [ -r /etc/os-release ]; then
  # Sourced in a subshell: os-release defines VERSION, NAME, ID, etc. —
  # sourcing it in the main shell silently clobbers same-named script vars.
  # shellcheck source=/dev/null
  OS_FAMILY="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  case "$OS_FAMILY" in
    *debian*) ;;
    *) warn "not a Debian-family system (${OS_FAMILY:-unknown}); proceeding anyway" ;;
  esac
else
  warn "cannot read /etc/os-release; proceeding anyway"
fi

# The tenant user is the SEED's to create (box.env BOX_USER + cloud-init), not
# rig's to conjure: a missing user means the seed and the role disagree, and
# inventing an account here would paper over exactly that mismatch.
id -u "$TENANT_USER" >/dev/null 2>&1 \
  || die "user '$TENANT_USER' does not exist — the box seed creates it (BOX_USER); pass --user <name> if this box's user differs"
TENANT_HOME="$(getent passwd "$TENANT_USER" | cut -d: -f6)"
TENANT_GROUP="$(id -gn "$TENANT_USER")"
[ -d "$TENANT_HOME" ] || die "user '$TENANT_USER' has no home directory ($TENANT_HOME)"

# append_line_once <file> <line> — converge a literal rc line: present exactly
# once, appended only when missing, ownership converged to the tenant user.
append_line_once() {
  local file="$1" line="$2"
  if [ ! -e "$file" ] || ! grep -qxF "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
    log "appended to ${file}: ${line}"
  fi
  chown "$TENANT_USER:$TENANT_GROUP" "$file"
}

# --- packages ----------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "installing base packages (tenant ${ROLE})"
apt-get update -qq
if [ "$ROLE" = "staging-box" ]; then
  # openssh-server: the hardening drop-in below targets /etc/ssh/sshd_config.d/,
  # which only exists once the package is installed — pristine container/VM
  # images (and thin seeds) do not ship it.
  apt-get install -y -qq curl ca-certificates tmux openssh-server
else
  # The shared agent toolbelt the templates carried, plus the definition's
  # APT_EXTRAS (claude-box's zsh rides there). Unquoted on purpose — it is a
  # word list, every word already vetted by the parser's package-name gate.
  # shellcheck disable=SC2086
  apt-get install -y -qq git gh curl ca-certificates gnupg ripgrep jq tmux age unzip build-essential $TPL_APT_EXTRAS
fi
# Assert the effective toolbelt, not apt's exit code — tmux is the box#65
# contract ('box tmux' runs tmux new-session inside every box) and gh is how
# the operator's git credential lands.
command -v tmux >/dev/null 2>&1 || die "tmux missing after package install — 'box tmux' (box#65) needs it"
if [ "$ROLE" != "staging-box" ]; then
  command -v gh  >/dev/null 2>&1 || die "gh missing after package install"
  command -v git >/dev/null 2>&1 || die "git missing after package install"
fi

# --- docker ------------------------------------------------------------------
# Every tenant gets docker (the templates all carried it; staging-box's workloads run
# their workloads in it). Docker's own installer, convergence-guarded — its
# script is not a no-op when docker exists, so rig supplies the guard.
if ! command -v docker >/dev/null 2>&1; then
  log "installing docker (get.docker.com)"
  curl -fsSL https://get.docker.com | sh
else
  log "docker already installed"
fi
docker --version >/dev/null 2>&1 || die "docker installed but 'docker --version' does not answer"
# The client answering is not the effective state — a dead dockerd would still
# pass it. Ask the daemon, with a bounded settle for the freshly-installed case
# (get.docker.com starts it, but not instantaneously on a slow guest).
docker_up=""
for _ in 1 2 3 4 5 6; do
  if docker info >/dev/null 2>&1; then docker_up=1; break; fi
  sleep 5
done
[ -n "$docker_up" ] || die "dockerd does not answer 'docker info' after 30s — the daemon is not running; check 'systemctl status docker' (or the container's init) before re-running"
log "dockerd answering"
if getent group docker >/dev/null 2>&1; then
  if id -nG "$TENANT_USER" | tr ' ' '\n' | grep -qx docker; then
    log "${TENANT_USER} already in the docker group"
  else
    usermod -aG docker "$TENANT_USER"
    log "added ${TENANT_USER} to the docker group"
  fi
else
  warn "no docker group after install — skipping the ${TENANT_USER} group add; check docker's install"
fi

# --- node (definitions carrying NEEDS_NODE="yes") ----------------------------
# An npm-installed CLI needs Node 22+ (codex — the SCOPED @openai/codex,
# verified upstream when the template was written); claude ships node as part
# of its toolbelt, same pin. Whether a tenant needs it is the DEFINITION's
# fact (NEEDS_NODE), never a role list here — grok's CLI is a self-contained
# binary and kimi's is uv-managed Python, so both say no.
node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local major
  major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+)\..*$/\1/')"
  [ "${major:-0}" -ge 22 ] 2>/dev/null
}
if [ "$ROLE" != "staging-box" ] && [ "$TPL_NEEDS_NODE" = "yes" ]; then
  if node_ok; then
    log "node $(node --version) already present"
  else
    log "installing node 22 (nodesource)"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
  fi
  node_ok || die "node >= 22 still missing after install — check the nodesource setup"
fi

# --- the agent CLI -----------------------------------------------------------
# Per-definition install, shared discipline: install only when the CLI is
# absent (upgrades are the CLI's own business) — presence is CLI_SRC when the
# definition names one, `command -v` when it does not (an npm global's path
# is the prefix's fact, not the data file's) — then put it on the SYSTEM
# path: 'box exec <box> -- <cli> …' runs a NON-interactive shell that reads
# no rc files, so a PATH export alone is invisible to it (the #15 lesson).
# And assert it ANSWERS as the tenant user: a CLI that exists but cannot run
# is what cost the last drill (the grok-box template's scar).
#
# install.sh — the definition's one executable part — runs AS ROOT with the
# tenant named in its environment (TENANT_USER/TENANT_HOME/TENANT_GROUP/ROLE);
# each definition drops to the tenant user itself (runuser -l) where the
# vendor's layout demands it, because some installs are inherently root's
# (codex's npm -g writes the global prefix). This is the trade #110 states in
# bold — a registry definition executes as root inside every future mint —
# and it is why install.sh diffs there are the highest-trust review surface
# in the org, why the default ref is a reviewed in-tree pin, and why the data
# file beside it is parsed rather than sourced.
CLI="" CLI_SRC=""
if [ "$ROLE" != "staging-box" ]; then
  CLI="$TPL_CLI_NAME"
  # '~/' in CLI_SRC is data — expanded to the tenant home HERE, by string
  # substitution, never by the shell (hence the literal quoted tilde, SC2088).
  # shellcheck disable=SC2088
  case "$TPL_CLI_SRC" in
    '~/'*) CLI_SRC="$TENANT_HOME/${TPL_CLI_SRC#'~/'}" ;;
    *)     CLI_SRC="$TPL_CLI_SRC" ;;
  esac
  installed=""
  if [ -n "$CLI_SRC" ]; then
    [ -e "$CLI_SRC" ] && installed=1
  elif command -v "$CLI" >/dev/null 2>&1; then
    installed=1
  fi
  if [ -z "$installed" ]; then
    log "installing the ${CLI} CLI (${ROLE}'s install.sh)"
    TENANT_USER="$TENANT_USER" TENANT_HOME="$TENANT_HOME" \
      TENANT_GROUP="$TENANT_GROUP" ROLE="$ROLE" \
      bash "$TPL_DIR/install.sh" \
      || die "${ROLE}'s install.sh failed — the definition is $(templates_source_desc)"
  else
    log "${CLI} CLI already installed"
  fi
  if [ -z "$CLI_SRC" ]; then
    CLI_SRC="$(command -v "$CLI" 2>/dev/null || true)"
    [ -n "$CLI_SRC" ] || die "the ${CLI} installer put no '${CLI}' on root's PATH and the definition names no CLI_SRC — upstream layout changed?"
  fi
  [ -e "$CLI_SRC" ] || die "the ${CLI} installer produced no ${CLI_SRC} — upstream layout changed?"
  ln -sf "$CLI_SRC" "/usr/local/bin/$CLI"
  # One capture serves both the assert and the log line; emptiness IS the
  # failure signal (head exits 0 regardless, so a pipeline status can't be).
  CLI_VER="$(runuser -l "$TENANT_USER" -c "$CLI --version" 2>/dev/null | head -n1)"
  [ -n "$CLI_VER" ] || die "'$CLI --version' does not answer for ${TENANT_USER} — the CLI landed but cannot run; check /usr/local/bin/$CLI and its target"
  log "${CLI} CLI on the system PATH and answering (${CLI_VER})"

  # The interactive-shell PATH export the templates carried, converged as a
  # literal rc line (written once, never duplicated). The definition's
  # PATH_LINE is DATA, appended verbatim: it must expand in the USER's
  # shell, not here.
  append_line_once "$TENANT_HOME/.bashrc" "$TPL_PATH_LINE"
fi

# --- the agent-context file --------------------------------------------------
# The one file every agent reads before touching anything. The skeleton —
# including the box#80 guard note ("never run box setup-host or the drill
# inside a box; the box you are in is not a host you own") — is MECHANISM,
# rendered from lib/templates.sh ONCE for all agents, never copy-pasted per
# template; only the creds paragraph is the definition's (creds.md).
# cmp-guarded like every file rig converges. staging-box has no agent and no
# context file.
if [ "$ROLE" != "staging-box" ]; then
  CTX_PATH="$TENANT_HOME/$TPL_CONTEXT_PATH"
  CTX_DIR="$(dirname "$CTX_PATH")"
  if [ ! -d "$CTX_DIR" ]; then
    mkdir -p "$CTX_DIR"
    log "created ${CTX_DIR}"
  fi
  # The dotdir is the AGENT's (it writes state next to its instructions), so
  # its ownership is converged on every run, not only on creation.
  chown "$TENANT_USER:$TENANT_GROUP" "$CTX_DIR"
  CTX_TMP="$(mktemp)"
  render_tenant_context "$ROLE" "$TPL_DIR/creds.md" > "$CTX_TMP"
  if ! cmp -s "$CTX_TMP" "$CTX_PATH" 2>/dev/null; then
    install -m 0644 -o "$TENANT_USER" -g "$TENANT_GROUP" "$CTX_TMP" "$CTX_PATH"
    log "agent-context file written: ${CTX_PATH}"
  else
    log "agent-context file already current"
  fi
  rm -f "$CTX_TMP"
fi

# --- staging-box server posture --------------------------------------------------
# box#69's posture, minus the join: docker (above) + sshd hardening, through
# the SAME code the machine roles use (lib/sshd.sh) — the staging-box guest is a
# workload server in waiting, and its door must never be password-open even
# before the operator joins it. root-door=open: root SSH stays the control
# plane's future automation door.
if [ "$ROLE" = "staging-box" ]; then
  harden_sshd open
fi

# --- role marker --------------------------------------------------------------
# Same ground truth the machine roles write, tenant-shaped: no root-door trait
# at all (a tenant has no root-door policy of its own — close-root fails closed
# on it), and host=no so `rig users apply` box-role gating keeps working.
# staging-box SKIPS the write when a machine marker is already present: after
# the operator-run workload join, the workload marker is the truer statement and
# rig never clobbers state a joined box earned.
#
# "Is a machine marker already here?" is the same question the guard above
# asks, and is asked the same way — through root_door_of, so both the current
# `root-door=` spelling and the pre-#77 `class=` one count (#77). Testing for
# one spelling would let this write CLOBBER a marker written in the other, which
# on a joined workload box means silently replacing its root-door policy with a
# tenant line that close-root then refuses on.
if [ -z "$EXISTING_ROOT_DOOR" ]; then
  MARKER_TMP="$(mktemp)"
  printf 'role=%s tenant=yes host=no\n' "$ROLE" > "$MARKER_TMP"
  if ! cmp -s "$MARKER_TMP" "$MARKER_PATH" 2>/dev/null; then
    mkdir -p "$(dirname "$MARKER_PATH")"
    install -m 0644 "$MARKER_TMP" "$MARKER_PATH"
    log "role marker written: role=$ROLE tenant=yes host=no"
  else
    log "role marker already current"
  fi
  rm -f "$MARKER_TMP"
else
  log "machine role marker present (${EXISTING_MARKER}); leaving it alone"
fi

# --- provenance manifest ------------------------------------------------------
# A tenant gets a manifest, in the SAME /etc/rig/manifest, through the same
# writer — and UNCONDITIONALLY, outside the marker gate above (#61's open
# question, answered here).
#
# The reason the marker needs that gate is that it holds TRAITS, and a guest's
# traits and the traits it earns after an operator-run `rig bootstrap workload`
# join are two different, competing statements about one box — so the marker
# has to pick, and it picks the truer one. Provenance has no such conflict.
# "Which rig converged this guest, and when" is a fact whichever bootstrap ran,
# and the two-pair shape composes across them exactly as designed: a staging
# guest later joined as a workload keeps the TENANT bootstrap as its birth —
# that genuinely is when this machine was first converged — and the machine
# bootstrap moves converged_* forward. Skipping the write on a joined guest
# would lose the birth stamp that only this run knows.
#
# One file, not a tenant-shaped second one: the manifest answers a question
# about the MACHINE, and a guest is a machine. The marker already carries
# `tenant=yes` for anyone who needs to know which kind.
if manifest_stamp "$(manifest_running_version "$HERE/..")"; then
  log "provenance manifest written: $(manifest_path)"
else
  log "provenance manifest already current"
fi

log "done — tenant ${ROLE}, user ${TENANT_USER}"
if [ "$ROLE" = "staging-box" ]; then
  log "next (operator-run, holds a credential): box shell → sudo rig bootstrap workload-server --hostname <name> with a tagged pre-auth key"
else
  log "next: creds stay with the operator — ${CLI} authenticates through its own interactive login when a human decides"
fi
