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

# --- instances (#166) --------------------------------------------------------
# A box runs any number of runners. The NAME is the key and the box is not: an
# instance is a directory holding one actions/runner install, one _work, one
# systemd unit. Two layouts coexist on purpose:
#
#   <base>          — the LEGACY single-instance layout, the only one rig could
#                     ever create. Every box installed before this exists is
#                     this shape, and it is adopted in place: never moved,
#                     never re-registered, never re-downloaded.
#   <base>/<name>   — one directory per named instance, the layout rig creates
#                     from now on. Siblings of the legacy dir, which is why a
#                     name that collides with the tarball's own top-level
#                     entries is refused rather than unpacked over.
#
# where <base> is the runner user's ~/actions-runner.

# runner_base_dir <user_home> — where this user's instances live.
runner_base_dir() { printf '%s' "$1/actions-runner"; }

# runner_is_instance_dir <dir> — 0 when <dir> holds a runner install.
#
# `.runner` (registered) OR `config.sh` (unpacked, maybe deregistered): remove
# takes the registration away and deliberately leaves the binary, so a dir that
# only had `.runner` to prove itself would vanish from every listing the moment
# it was removed — and `install` would then create a SIBLING beside the binary
# it was meant to re-use.
runner_is_instance_dir() {
  [ -e "$1/.runner" ] || [ -e "$1/config.sh" ]
}

# runner_instance_name <dir> — the name of the instance in <dir>.
#
# Three sources, in falling order of authority: `.rig-instance` (what rig
# registered it AS, and the only one that survives a `remove`), the runner's
# own `.runner`, then the directory name. The last is the legacy dir's answer
# when it holds neither — it reads "actions-runner", which is honest: that box
# never told anyone a name.
runner_instance_name() {
  local name=""
  [ -r "$1/.rig-instance" ] && name="$(head -n1 "$1/.rig-instance")"
  [ -n "$name" ] || name="$(runner_agent_name "$1")"
  [ -n "$name" ] || name="$(basename "$1")"
  printf '%s' "$name"
}

# runner_dir_unit <dir> — the systemd unit svc.sh recorded, empty when the
# instance was never installed as a service.
runner_dir_unit() {
  [ -r "$1/.service" ] || return 0
  head -n1 "$1/.service"
}

# runner_unit_name <unit> — the runner name inside an actions.runner.* unit.
#
# svc.sh names units `actions.runner.<owner>-<repo>.<name>.service`, so the
# name is what follows the last dot. A repository or a runner name containing
# a dot defeats that — which is why this is the LAST fallback, used only for a
# unit whose directory rig cannot read.
runner_unit_name() {
  local u="${1#actions.runner.}"
  u="${u%.service}"
  printf '%s' "${u##*.}"
}

# runner_valid_name <name> — 0 when <name> is usable as a directory name.
# Deliberately narrower than the filesystem: a name is a path component here,
# and `..`, a slash, or a leading dot would each escape or hide the instance.
runner_valid_name() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# runner_scan_units — one "unit<TAB>dir" line per actions.runner.* service this
# box's systemd knows about, whether rig created it or not.
#
# This is the migration rule from #166, and the reason discovery reads systemd
# rather than a registry rig maintains: a box with three hand-rolled siblings
# beside rig's one must SHOW all four. A registry would only ever list rig's,
# and `status` reporting one of four is the actual bug — a command that looks
# like it did the whole job.
#
# Prints nothing where there is no systemd, so every caller degrades to "rig's
# own instances only" rather than dying.
runner_scan_units() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local unit dir
  { systemctl list-units --all --no-legend --plain --type=service 'actions.runner.*' 2>/dev/null || true
    systemctl list-unit-files --no-legend --plain --type=service 'actions.runner.*' 2>/dev/null || true
  } | awk '{ print $1 }' | grep -E '^actions\.runner\..*\.service$' | sort -u \
  | while read -r unit; do
      dir="$(systemctl show -p WorkingDirectory --value "$unit" 2>/dev/null || true)"
      printf '%s\t%s\n' "$unit" "$dir"
    done
}

# runner_merge_instances <base>  (stdin: runner_scan_units' "unit<TAB>dir" lines)
#
# The whole instance list for a box, one line each:
#   <name><TAB><dir><TAB><unit><TAB>managed|unmanaged<TAB>live|dormant
#
# LIVE vs DORMANT is the difference between a runner and a directory. `remove`
# deregisters and deliberately keeps the binary, so the directory outlives the
# runner: it still holds an install (which is why `install` must find it and
# re-use it) and holds no runner (which is why `status` must not report one,
# and `remove` must go on saying there is nothing to remove). Live means a
# registration or a unit; everything else is dormant. Callers that answer
# "what does this box run" filter with runner_live; `install`, which answers
# "where does this name belong", does not.
#
# rig's own instances first — the legacy <base> when it holds one, then every
# <base>/<name> — followed by every scanned unit whose WorkingDirectory is none
# of them. `unmanaged` is not a warning: it is the honest word for a runner
# someone registered with config.sh by hand, which is how boxes get concurrency
# today and must therefore be visible rather than invisible.
#
# The units arrive on stdin rather than being scanned here so the merge stays
# offline-testable — the harness has no systemd and cannot fabricate one.
runner_merge_instances() {
  local base="$1" units d n u name dir
  units="$(cat)"
  local managed=""

  if [ -n "$base" ]; then
    for d in "$base" "$base"/*; do
      [ -d "$d" ] || continue
      runner_is_instance_dir "$d" || continue
      n="$(runner_instance_name "$d")"
      u="$(runner_dir_unit "$d")"
      # A dir with no .service can still have a unit — one installed before rig
      # recorded it, or by hand. Ask the scan before giving up on it.
      [ -n "$u" ] || u="$(printf '%s' "$units" | awk -F'\t' -v dd="$d" '$2 == dd { print $1; exit }')"
      if [ -e "$d/.runner" ] || [ -n "$u" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$d" "$u" "managed" "live"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$d" "$u" "managed" "dormant"
      fi
      managed="${managed}${d}
"
    done
  fi

  # `%s\n`, not `%s`: $(cat) strips the trailing newline, and `read` returns
  # non-zero on an unterminated final line — dropping the LAST unit silently,
  # which on a box with one hand-rolled runner is the whole finding.
  #
  # cut, not `read -r unit dir`: TAB is an IFS *whitespace* character, so read
  # collapses a run of them — and a unit whose WorkingDirectory systemd cannot
  # report has exactly the empty field that would then shift.
  printf '%s\n' "$units" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    unit="$(printf '%s' "$line" | cut -f1)"
    dir="$(printf '%s' "$line" | cut -f2)"
    if [ -n "$dir" ] && printf '%s' "$managed" | grep -qxF "$dir"; then
      continue
    fi
    if [ -n "$dir" ] && [ -e "$dir/.runner" ]; then
      name="$(runner_instance_name "$dir")"
    else
      name="$(runner_unit_name "$unit")"
    fi
    # Always live: a scanned unit IS a runner the box runs, whatever rig can
    # read of the directory behind it.
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$dir" "$unit" "unmanaged" "live"
  done
}

# runner_live — the instances a box actually RUNS, on stdin, on stdout.
# The filter every "what is on this box" question applies, and the one
# `install` does not.
runner_live() { awk -F'\t' 'NF && $5 == "live"'; }

# runner_pick <name> <instances> — the instance line named <name>, or exit 1.
# Every duplicate is printed: two instances answering to one name is a state a
# hand-rolled sibling can reach, and the caller must be able to say so rather
# than silently act on the first.
runner_pick() {
  printf '%s\n' "$2" | awk -F'\t' -v n="$1" 'NF && $1 == n { print; f = 1 } END { exit !f }'
}

# runner_candidates <instances> — the list a refusal names, one indented line
# each. A refusal that says "pass --name" without saying which names exist
# makes the operator go and look; this is the looking.
runner_candidates() {
  printf '%s\n' "$1" | awk -F'\t' 'NF { printf "  %-24s %s  [%s]\n", $1, ($2 == "" ? "(dir unknown)" : $2), $4 }'
}

# runner_count <instances> — how many instances the box has.
runner_count() { printf '%s\n' "$1" | grep -c . || true; }

# runner_resolve_instance <base> <name> <name_given 0|1> <instances>
#
# Where `install` should put this instance. Prints "<dir><TAB><name>" and
# returns 0; prints the refusal on stderr and returns 1.
#
# It lives here, beside assert_runner_repo and for the same reason: reaching it
# through the CLI needs root and a really-registered runner, neither of which
# the test harness can fabricate, and the rules below are exactly the ones the
# acceptance criteria are about.
runner_resolve_instance() {
  local base="$1" name="$2" given="$3" instances="$4" line dir

  # The one rule that reads the box rather than the name, and the whole of the
  # migration: a box whose runner lives in the legacy <base> layout keeps it.
  # Omitting --name there means "the runner this box already has", whatever it
  # is called — which is what omitting it meant before instances existed, so
  # such a box converges with the same dir, the same unit and no
  # re-registration. Pass a name and you get an instance, including beside it.
  if [ "$given" -eq 0 ] && runner_is_instance_dir "$base"; then
    printf '%s\t%s\n' "$base" "$(runner_instance_name "$base")"
    return 0
  fi

  if line="$(runner_pick "$name" "$instances")"; then
    if [ "$(runner_count "$line")" -ne 1 ]; then
      printf 'rig-runner: ERROR: %s\n' \
"more than one runner on this box answers to '${name}':
$(runner_candidates "$line")
rig will not guess which one you meant." >&2
      return 1
    fi
    # An unmanaged instance is someone's hand-rolled runner. Registering over
    # its name is not convergence: config.sh --replace would deregister it and
    # rig would report success, which is the class of bug #166 is about.
    if [ "$(printf '%s' "$line" | cut -f4)" = "unmanaged" ]; then
      printf 'rig-runner: ERROR: %s\n' \
"the name '${name}' is taken by a runner rig did not create:
$(runner_candidates "$line")
registering over it would deregister that runner (config.sh --replace).
Pick another --name, or take that one down first." >&2
      return 1
    fi
    printf '%s\t%s\n' "$(printf '%s' "$line" | cut -f2)" "$name"
    return 0
  fi

  # A new instance. Refusing an occupied path is what keeps a name out of the
  # tarball's own top-level entries (bin/, externals/, config.sh) on a box
  # carrying the legacy layout, with no reserved-word list to keep in sync.
  dir="$base/$name"
  if [ -e "$dir" ] && ! runner_is_instance_dir "$dir"; then
    printf 'rig-runner: ERROR: %s\n' \
"${dir} exists and is not a runner install — choose another --name" >&2
    return 1
  fi
  printf '%s\t%s\n' "$dir" "$name"
}

# runner_select_instance <name> <instances> <hint>
#
# Which instance `remove` and `repoint` act on. Prints the chosen instance line
# and returns 0; prints the refusal, with <hint> as its closing line, and
# returns 1.
#
# The empty-name-with-several case is the whole point (#166): "the runner" is
# not a thing anyone can mean on a box running four, and acting on one of them
# and exiting 0 is a command that looks like it did the whole job.
runner_select_instance() {
  local name="$1" instances="$2" hint="$3" count line
  count="$(runner_count "$instances")"

  if [ -n "$name" ]; then
    if ! line="$(runner_pick "$name" "$instances")"; then
      printf 'rig-runner: ERROR: %s\n' \
"no runner named '${name}' on this box. It runs:
$(runner_candidates "$instances")" >&2
      return 1
    fi
    if [ "$(runner_count "$line")" -ne 1 ]; then
      printf 'rig-runner: ERROR: %s\n' \
"more than one runner on this box answers to '${name}':
$(runner_candidates "$line")
rig will not guess which one you meant." >&2
      return 1
    fi
    printf '%s\n' "$line"
    return 0
  fi

  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$instances"
    return 0
  fi

  printf 'rig-runner: ERROR: %s\n' \
"this box runs ${count} runners — say which one:
$(runner_candidates "$instances")
${hint}" >&2
  return 1
}

# assert_runner_repo <runner_dir> <owner/repo> [instance_name]
#
# Returns 0 when the INSTANCE in <runner_dir> has no runner, or has one already
# registered to <owner/repo>: re-running `install` against the repo that
# instance is already on is real convergence — it re-uses the binary, skips
# registration, exits 0.
#
# Returns 1, explaining itself on stderr, when the instance is registered to a
# DIFFERENT repo. Skipping *that* is not convergence, it is ignoring the
# argument: `install` would skip its configure step, restart the service on the
# OLD repo, and report success — leaving the repo you asked for with no runner
# and its jobs queued against one that will never come. Moving a runner between
# repos is a trust-boundary act, so it belongs to `repoint`, out loud.
#
# Scoped to one instance since #166: on a box running four, "this box's runner"
# named a thing that does not exist. The name is optional so the guard keeps
# working on a dir whose instance has no recorded name.
assert_runner_repo() {
  local dir="$1" repo="$2" name="${3:-}" current wanted subject select
  [ -e "$dir/.runner" ] || return 0

  current="$(runner_repo_url "$dir")"
  wanted="https://github.com/${repo}"
  if [ -n "$name" ]; then
    subject="runner ${name}"
    select=" --name ${name}"
  else
    subject="this box's runner"
    select=""
  fi

  if [ -z "$current" ]; then
    printf 'rig-runner: ERROR: %s\n' \
"${dir}/.runner exists but names no repository — the registration of ${subject}
cannot be read, so rig cannot tell whether it is already on ${wanted}.
Wipe the local registration and install again:
  rig runner remove --local${select}" >&2
    return 1
  fi

  if [ "$current" = "$wanted" ]; then
    return 0
  fi

  printf 'rig-runner: ERROR: %s\n' \
"${subject} is already registered to ${current}, not ${wanted}.
install will not move a runner between repositories: it would leave the service
running against the OLD repo and report success. To move it in one act:
  rig runner repoint --repo ${repo}${select}
or take it off the old repo first, then install:
  rig runner remove${select}             (deregisters from ${current}; needs a removal token)
  rig runner remove --local${select}     (when you cannot mint one)
To run a SECOND runner here instead of moving this one, give the new one its
own name:
  rig runner install --repo ${repo} --name <name>" >&2
  return 1
}
