#!/usr/bin/env bash
# rig bootstrap --undo — remove only off-box state rig can prove it created.
set -euo pipefail

log() { printf 'rig-bootstrap: %s\n' "$*"; }
die() { printf 'rig-bootstrap: ERROR: %s\n' "$*" >&2; exit 1; }

MARKER="${RIG_ROLE_MARKER:-/etc/rig/role}"

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -e "$MARKER" ] || die "no /etc/rig/role marker — refusing to touch the tailnet"

runner_installed=0
if [ -n "${RIG_RUNNER_DIR:-}" ]; then
  [ -e "$RIG_RUNNER_DIR/.runner" ] && runner_installed=1
else
  # Two levels, because a box may carry multiple externally managed runners
  # (#166): the legacy single-instance layout puts .runner in actions-runner/
  # itself, and named instances put it in actions-runner/<name>/. A glob that
  # only knew the first would let undo proceed with other runners registered.
  for runner_config in \
    /home/*/actions-runner/.runner /home/*/actions-runner/*/.runner \
    /root/actions-runner/.runner /root/actions-runner/*/.runner; do
    [ -e "$runner_config" ] && runner_installed=1
  done
  compgen -G '/etc/systemd/system/actions.runner.*.service' >/dev/null \
    && runner_installed=1
fi
if [ "$runner_installed" -eq 1 ]; then
  die "a GitHub runner is installed — deregister it outside rig before retrying so undo does not leave a ghost runner in GitHub"
fi

join_by=""
while IFS= read -r field; do
  case "$field" in
    join-by=*) join_by="${field#join-by=}" ;;
  esac
done < <(tr '[:space:]' '\n' < "$MARKER")

case "$join_by" in
  rig) ;;
  preexisting)
    die "the tailnet join predates this bootstrap run (join-by=preexisting), so rig will not remove state it did not create; run 'tailscale logout' by hand if that is intended" ;;
  "")
    die "the role marker predates join-by provenance, so rig cannot prove it made this tailnet join and will not remove it; re-run bootstrap to write a current marker, or run 'tailscale logout' by hand" ;;
  *)
    die "the role marker has unknown join-by=$join_by, so rig cannot prove it made this tailnet join and will not remove it; run 'tailscale logout' by hand if that is intended" ;;
esac

# The same back-out/keep law as first-join verification: logout is earned only
# when the marker proves rig performed the join. Preserve the marker on failure
# so the operation remains retryable and never reports a half-undone machine.
if ! tailscale logout; then
  die "tailscale logout failed; role marker kept so 'rig bootstrap --undo' can be retried"
fi

rm -f -- "$MARKER"
log "tailnet join removed; role marker removed"
