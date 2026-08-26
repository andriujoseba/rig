#!/usr/bin/env bash
# rig platform — what is this machine? Calculated at run time, stored nowhere.
#
# Read-only in the strongest sense rig has: it reads /proc, uname,
# /etc/os-release, /etc/machine-id, df and systemd-detect-virt, and writes
# NOTHING, ever. That
# is the design, not an implementation detail — specs change without rig doing
# anything (RAM added, root disk resized, unattended-upgrades patching the
# kernel), so a stored spec is stale the moment the machine changes, and
# refreshing one on every run would collide with bootstrap's convergence
# contract ("safe to re-run; a second run changes nothing").
#
# The corollary is worth having deliberately: this runs on a machine rig has
# never converged, and needs no root. It answers "what should I converge this
# into?", not only "what did I converge this into?".
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"   # read_role_marker — one reader of /etc/rig/role

die() { printf 'rig-platform: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig platform

Describes the machine you are on: hostname, a stable machine ID, OS, kernel,
CPU, memory, disk and virtualization, then rig's own provenance (which rig,
when, and the role marker bootstrap wrote).

ID names the machine where HOSTNAME names the slot: it is derived from
/etc/machine-id (a namespaced sha256, never the raw value, which machine-id(5)
asks tools not to expose). Two machines reporting the same ID were cloned
from one image — actionable information, not a coincidence: no identity that
lives in the filesystem survives the filesystem being copied.

Computed at run time from /proc, uname, /etc/os-release, /etc/machine-id, df
and systemd-detect-virt. Writes nothing, needs no root, makes no network call
— so it also works on a pristine Debian box rig has never bootstrapped, where
the provenance block reads 'not bootstrapped'.
EOF
}

# --- args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# One aligned column for every line, so the output diffs cleanly across a
# fleet and reads as one table rather than a log.
field() { printf '%-10s %s\n' "$1" "$2"; }

# --- hostname ---------------------------------------------------------------
# uname -n is the coreutils fallback: `hostname` lives in its own package and a
# minimal image may not carry it, and this command's whole point is running
# before anything has been installed.
HOSTNAME_V="$(hostname 2>/dev/null || uname -n)"

# --- identity (#95) -----------------------------------------------------------
# HOSTNAME names the slot; ID names the machine. rig itself sets the hostname
# during bootstrap and reuses it across rebuilds ('hetzner-cp-1' is a role, not
# hardware), so nothing above answers "is this the same machine I converged in
# June, or its replacement?". /etc/machine-id does — but machine-id(5) asks
# that the raw value not be exposed (it is a stable correlator across every
# tool that leaks it), and its documented remedy is an application-specific
# derivation. So: THE PINNED DERIVATION, fixed by #95 so two implementations
# can never disagree —
#
#   printf 'rig-machine-id:%s' "$(cat /etc/machine-id)" | sha256sum
#   → first 32 hex chars, rendered 8-4-4-4-12
#
# The 'rig-machine-id:' prefix is the contract, not decoration: it is what
# keeps this id uncorrelatable with any other tool's derivation of the same
# machine-id. sha256sum is coreutils, which this command is restricted to.
# Derived, computed here, stored nowhere — #64's thesis — so it exists before
# bootstrap and needs no write path.
#
# What this deliberately does NOT fix: a host cloned from a golden image
# carries the clone's /etc/machine-id, so two machines reporting the same ID
# means a cloned image. That is surfaced (help text, README) rather than
# defended against — no identity that lives in the filesystem survives the
# filesystem being copied.
#
# RIG_MACHINE_ID overrides the path so the harness can drive the present,
# absent, empty and uninitialized cases against fixtures (repo precedent:
# RIG_MANIFEST / RIG_ROLE_MARKER below).
MID_FILE="${RIG_MACHINE_ID:-/etc/machine-id}"
ID_V=""
if [ ! -r "$MID_FILE" ]; then
  # Never an empty string: an ID field that renders blank looks like a bug,
  # and a missing file is a fact worth naming.
  ID_V="unavailable (no $MID_FILE)"
else
  # $(...) strips the trailing newline — that is part of the pinned derivation
  # above, not an accident of shell.
  MID="$(cat "$MID_FILE")"
  if [ -z "$MID" ]; then
    # NEVER a hash of nothing: hashing the empty string would hand every such
    # machine the SAME id — the worst possible failure for an identity field.
    # Images do ship the file empty (that is first-boot semantics per
    # machine-id(5)), so this path is real, not defensive.
    ID_V="unavailable ($MID_FILE is empty)"
  elif [ "$MID" = "uninitialized" ]; then
    # machine-id(5)'s other not-yet-set sentinel — same collision failure as
    # empty if hashed, so same loud degradation.
    ID_V="unavailable ($MID_FILE is uninitialized)"
  else
    MID_HASH="$(printf 'rig-machine-id:%s' "$MID" | sha256sum)"
    MID_HASH="${MID_HASH%% *}"
    ID_V="${MID_HASH:0:8}-${MID_HASH:8:4}-${MID_HASH:12:4}-${MID_HASH:16:4}-${MID_HASH:20:12}"
  fi
fi

# --- OS ---------------------------------------------------------------------
# THE os-release TRAP: /etc/os-release defines VERSION, NAME and ID, so
# sourcing it in the MAIN shell silently clobbers same-named script variables.
# Every site in this tree sources it in a SUBSHELL instead (bootstrap.sh:305,
# bootstrap-tenant.sh:126, db.sh:52,
# coolify-backup-install.sh:88), and test/cli.sh greps commands/ to keep it
# that way. Follow the form verbatim.
if [ -r /etc/os-release ]; then
  OS="$(. /etc/os-release && printf '%s %s' "${NAME:-}" "${VERSION:-${VERSION_ID:-}}")"
else
  OS=""
fi

# --- kernel -----------------------------------------------------------------
KERNEL="$(uname -r) ($(uname -m))"

# --- CPU --------------------------------------------------------------------
# 'model name' is x86's spelling; arm64 /proc/cpuinfo has no such field, so an
# unnamed CPU still reports its core count rather than nothing at all.
CPU_MODEL="$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
CORES="$(nproc 2>/dev/null || true)"

# --- memory -----------------------------------------------------------------
# /proc/meminfo is in kB. MemAvailable is the kernel's own estimate of what a
# new workload could claim (MemFree undercounts badly, reclaimable cache being
# most of a busy box's RAM); it predates every kernel rig targets, but degrade
# rather than print a wrong number if it is missing.
mem_kb() { awk -v k="$1" '$1 == k":" {print $2; exit}' /proc/meminfo 2>/dev/null || true; }
MEM_TOTAL_KB="$(mem_kb MemTotal)"
MEM_AVAIL_KB="$(mem_kb MemAvailable)"
human_kb() {   # kB -> IEC, matching df's units below
  [ -n "${1:-}" ] || { printf 'unknown'; return 0; }
  numfmt --to=iec-i "$(( $1 * 1024 ))" 2>/dev/null || printf '%s kB' "$1"
}

# --- disk -------------------------------------------------------------------
# -P is the one-line-per-filesystem guarantee (a long device name otherwise
# wraps and breaks field positions); -B1 gives bytes, so numfmt renders the
# same IEC units as memory above instead of df's own bare 'G'.
DISK_TOTAL="" DISK_FREE=""
if DF="$(df -PB1 / 2>/dev/null)"; then
  DISK_TOTAL="$(printf '%s\n' "$DF" | awk 'NR==2 {print $2}')"
  DISK_FREE="$(printf '%s\n' "$DF" | awk 'NR==2 {print $4}')"
fi
human_b() {   # bytes -> IEC; falls back like human_kb rather than to 'unknown'
  [ -n "${1:-}" ] || { printf 'unknown'; return 0; }
  numfmt --to=iec-i "$1" 2>/dev/null || printf '%s B' "$1"
}

# --- virtualization ---------------------------------------------------------
# THE set -e TRAP: systemd-detect-virt exits NON-ZERO on bare metal while
# printing 'none'. That is a normal, correct answer — without the `|| true` a
# bare-metal machine would turn this whole command into a failed run. The
# substitution also swallows the binary being absent entirely (a non-systemd
# box), which lands as 'unknown'.
VIRT="$(systemd-detect-virt 2>/dev/null || true)"

printf '%s\n' "PLATFORM"
field HOSTNAME "$HOSTNAME_V"
field ID       "$ID_V"
field OS       "${OS:-unknown}"
field KERNEL   "$KERNEL"
field CPU      "${CPU_MODEL:-unknown}${CORES:+ ($CORES cores)}"
field MEMORY   "$(human_kb "$MEM_TOTAL_KB") total, $(human_kb "$MEM_AVAIL_KB") available"
field DISK     "$(human_b "$DISK_TOTAL") total, $(human_b "$DISK_FREE") free on /"
field VIRT     "${VIRT:-unknown}"
echo

# --- provenance: READ, never written ----------------------------------------
# The complementary half of the answer — which rig, and when — is decided
# rather than observed, so unlike everything above it IS stored. rig writes it
# during bootstrap; this command only ever reads it.
#
# /etc/rig/manifest is #61 and is NOT implemented yet, so on every machine in
# existence today this block reads 'not bootstrapped'. That degradation is the
# point: the two features are independent and neither blocks the other. The
# parse is the flat key=value shape the manifest is specified to use — the
# same jq-free shape /etc/rig/users and /etc/rig/role already use, parseable
# with `read` on a box that has no YAML parser.
#
# RIG_MANIFEST / RIG_ROLE_MARKER override the paths so the harness can drive
# both the present and the absent case against fixtures, non-root, without a
# real marker on the machine running the tests (repo precedent: the
# RIG_ROLE_MARKER gate in bin/rig, install.sh and users-close-root.sh).
MANIFEST="${RIG_MANIFEST:-/etc/rig/manifest}"
MARKER="${RIG_ROLE_MARKER:-/etc/rig/role}"

manifest_field() {   # $1 = key — empty when absent, unreadable or unset
  local k v
  [ -r "$MANIFEST" ] || return 0
  # `|| [ -n "$k" ]` so a manifest whose last line lacks a trailing newline
  # still yields that line: read returns 1 at EOF even having filled k/v.
  # Same guard parse_users_file uses (lib/users-config.sh:47) — #61's writer
  # should not have to know whether this reader tolerates a missing \n.
  while IFS='=' read -r k v || [ -n "$k" ]; do
    [ "$k" = "$1" ] || continue
    printf '%s\n' "$v"
    return 0
  done < "$MANIFEST"
  return 0
}

printf '%s\n' "PROVENANCE"
# Keys are #61's documented schema verbatim — schema/bootstrapped_by/
# bootstrapped_at/converged_by/converged_at — NOT invented ones. #61 keeps
# birth and latest deliberately separate ("is this machine converged by a rig
# that predates the fix?"), so both are reported and neither is inferred from
# the other: CONVERGED answers currency, BOOTSTRAPPED answers provenance.
# Every field degrades independently, so a partial manifest from a future
# schema still renders what it does carry.
if [ -r "$MANIFEST" ]; then
  M_SCHEMA="$(manifest_field schema)"
  B_BY="$(manifest_field bootstrapped_by)"; B_AT="$(manifest_field bootstrapped_at)"
  C_BY="$(manifest_field converged_by)";    C_AT="$(manifest_field converged_at)"
  # A manifest with no schema= line is pre-#61; say so rather than render blanks.
  if [ -z "$M_SCHEMA$B_BY$B_AT$C_BY$C_AT" ]; then
    field RIG "manifest present but carries no recognised fields ($MANIFEST)"
  else
    # 'not recorded' rather than 'unknown', and it does NOT describe a fresh
    # box: #61's writer records both pairs equally at bootstrap, so no writer
    # produces a manifest missing converged_* — its absence means the file is
    # partial or hand-edited. Deliberately not backfilled from bootstrapped_*,
    # because inferring a convergence that never happened is worse than saying
    # the record is not there. README and the fixtures pin exactly this.
    field CONVERGED "${C_BY:-not recorded}${C_AT:+, $C_AT}"
    field BOOTSTRAP "${B_BY:-not recorded}${B_AT:+, $B_AT}"
    [ -n "$M_SCHEMA" ] && [ "$M_SCHEMA" != "1" ] && \
      field NOTE "manifest schema=$M_SCHEMA is newer than this rig reads (expects 1)"
  fi
else
  field RIG "not bootstrapped (no $MANIFEST)"
fi

# The role marker is bootstrap's own line — 'role=dev-server
# root-door=closed host=yes join=authkey' — printed as the role plus its
# traits. The example tracks the CURRENT vocabulary (#76's -server/-box role
# suffixes, #77's root-door trait); this command renders whatever fields the
# marker carries, so a pre-rename box still prints its own class= line as-is.
MARKER_LINE="$(read_role_marker "$MARKER")"
if [ -n "$MARKER_LINE" ]; then
  ROLE_NAME="" ROLE_TRAITS=""
  for kv in $MARKER_LINE; do
    case "$kv" in
      role=*) ROLE_NAME="${kv#role=}" ;;
      *)      ROLE_TRAITS="${ROLE_TRAITS:+$ROLE_TRAITS }$kv" ;;
    esac
  done
  field ROLE "${ROLE_NAME:-unknown}${ROLE_TRAITS:+ ($ROLE_TRAITS)}"
else
  field ROLE "not bootstrapped (no $MARKER)"
fi
