#!/usr/bin/env bash
# Shared reader for the runner's own on-disk config ($RUNNER_DIR/.runner).
# Sourced by the runner-* commands; never executed on its own.

# .runner is JSON, parsed here with grep/sed on purpose: a rig-bootstrapped box
# has no jq, and installing one to read two fields would be a poor trade.
#
# json_field <file> <key> — the first string value for <key>, empty if absent.
# Never fails: callers run under `set -e` with pipefail, where a grep that
# matches nothing would otherwise kill the script with no message. A missing
# key is a fact to test for, not an error to die on.
json_field() {
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
    | head -n1 | sed 's/.*:[[:space:]]*"//; s/"$//' || true
}

# json_string_array <file> <key> — the elements of the array named <key> inside
# the netmap's `Self` object, one per line; empty when Self or the key is absent.
#
# json_field's sibling for the one shape it cannot read: `.Self.Tags` from
# `tailscale status --json` is a JSON array, and bootstrap must assert on it to
# learn the tag control actually GRANTED the node (the netmap's ground truth),
# not the tag rig requested. Same grep/sed spirit, same jq-free reason: a
# rig-bootstrapped box has no jq and we will not install one to read one field.
#
# Scoped to Self, NOT document-global. The previous body took the first "Tags"
# array anywhere in the file and justified it with Self-before-Peer field order.
# That holds only when Self HAS tags: an untagged Self omits the key entirely
# (Go omitempty), so the match fell through into Peer and returned a PEER's tag
# — silently inverting both callers on any tailnet with a tagged node (#160).
#
# Self is brace-counted rather than sliced to the next key: PeerStatus carries a
# nested object (Location, a pointer with omitempty), which would end a naive
# slice early whenever it is present. Known limit of staying jq-free: a `{` or
# `}` inside a STRING value within Self would miscount — no PeerStatus string
# field (hostnames, DNS names, OS, key strings) can contain one, so this is
# sound in practice, but it is a real assumption, written down on purpose.
#
# `tr -d '\n'` first, because tailscale pretty-prints its JSON and the object
# spans lines — awk and grep are line-oriented and would never see it whole
# otherwise. `\[[^]]*\]` then captures the flat array body for <key> (tag
# strings never contain `]`, so this is safe); the inner `grep -o` pulls every
# quoted token out of it, and `sed 1d` drops the key's own name — which
# `"key":[...]` leads with — leaving just the elements. Never fails under
# `set -e`+pipefail: a non-match is a fact to test for, not a reason to die.
json_string_array() {
  local self
  self="$(tr -d '\n' < "$1" 2>/dev/null | awk '
    {
      i = index($0, "\"Self\"")
      if (i == 0) exit
      s = substr($0, i)
      j = index(s, "{")
      if (j == 0) exit
      depth = 0
      for (k = j; k <= length(s); k++) {
        c = substr(s, k, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print substr(s, j, k - j + 1); exit } }
      }
    }')" || true
  [ -n "$self" ] || return 0
  printf '%s' "$self" \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\[[^]]*\]" \
    | head -n1 | grep -o '"[^"]*"' | sed '1d; s/^"//; s/"$//' || true
}

# runner_repo_url <runner_dir> — the repository this box's runner is registered
# to, empty when nothing is registered there.
runner_repo_url() {
  [ -e "$1/.runner" ] || return 0
  json_field "$1/.runner" gitHubUrl
}

# runner_agent_name <runner_dir> — the runner's name, empty when unregistered.
runner_agent_name() {
  [ -e "$1/.runner" ] || return 0
  json_field "$1/.runner" agentName
}

# assert_runner_repo <runner_dir> <owner/repo>
#
# Returns 0 when the box has no runner, or has one already registered to
# <owner/repo>: re-running `install` against the repo the box is already on is
# real convergence — it re-uses the binary, skips registration, exits 0.
#
# Returns 1, explaining itself on stderr, when the runner is registered to a
# DIFFERENT repo. Skipping *that* is not convergence, it is ignoring the
# argument: `install` would skip its configure step, restart the service on the
# OLD repo, and report success — leaving the repo you asked for with no runner
# and its jobs queued against one that will never come. Moving a runner between
# repos is a trust-boundary act, so it belongs to `repoint`, out loud.
assert_runner_repo() {
  local dir="$1" repo="$2" current wanted
  [ -e "$dir/.runner" ] || return 0

  current="$(runner_repo_url "$dir")"
  wanted="https://github.com/${repo}"

  if [ -z "$current" ]; then
    printf 'rig-runner: ERROR: %s\n' \
"${dir}/.runner exists but names no repository — this box's registration cannot
be read, so rig cannot tell whether it is already on ${wanted}.
Wipe the local registration and install again:
  rig runner remove --local" >&2
    return 1
  fi

  if [ "$current" = "$wanted" ]; then
    return 0
  fi

  printf 'rig-runner: ERROR: %s\n' \
"this box's runner is already registered to ${current}, not ${wanted}.
install will not move a runner between repositories: it would leave the service
running against the OLD repo and report success. To move it in one act:
  rig runner repoint --repo ${repo}
or take it off the old repo first, then install:
  rig runner remove             (deregisters from ${current}; needs a removal token)
  rig runner remove --local     (when you cannot mint one)" >&2
  return 1
}
