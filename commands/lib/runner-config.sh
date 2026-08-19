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

# runner_scope_from_url <github-url> — repo|org when the runner target has one
# of GitHub's two supported registration shapes, empty when it cannot be read.
runner_scope_from_url() {
  local target="${1#https://github.com/}"
  [ "$target" != "$1" ] || return 0
  target="${target%/}"
  case "$target" in
    */*) printf 'repo' ;;
    ?*)  printf 'org' ;;
  esac
}

# runner_token_endpoint <github-url> <registration-token|remove-token>
runner_token_endpoint() {
  local url="$1" kind="$2" target scope
  target="${url#https://github.com/}"
  scope="$(runner_scope_from_url "$url")"
  case "$scope" in
    repo) printf 'repos/%s/actions/runners/%s' "$target" "$kind" ;;
    org)  printf 'orgs/%s/actions/runners/%s' "$target" "$kind" ;;
  esac
}

# runner_record_value <runner_dir> <scope|group|labels>
#
# New registrations carry a format marker followed by all three fields in
# .rig-labels. The marker is not enough on its own: a pre-#165 file may contain
# ANY legal one-line label value, including the marker itself. Requiring a
# second, scope-shaped line keeps every one-line legacy record unambiguous.
# Legacy files remain readable as labels and say nothing about scope or group,
# which are therefore reported honestly as unrecorded.
runner_record_value() {
  local file="$1/.rig-labels" key="$2"
  [ -r "$file" ] || return 0
  if [ "$(sed -n '1p' "$file")" = "format=rig-runner-state-v1" ] \
    && sed -n '2p' "$file" | grep -qE '^scope=(repo|org)$'; then
    sed -n "s/^${key}=//p" "$file" | head -n1
  elif [ "$key" = "labels" ]; then
    head -n1 "$file"
  fi
}

# runner_write_record <runner_dir> <scope> <group> <labels>
runner_write_record() {
  printf 'format=rig-runner-state-v1\nscope=%s\ngroup=%s\nlabels=%s\n' \
    "$2" "$3" "$4" > "$1/.rig-labels"
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

# runner_named <dir> <fallback> — the name of the instance in <dir>, falling
# back to <fallback> when the directory itself says nothing.
#
# Three sources, in falling order of authority: `.rig-instance` (what rig
# registered it AS, and the only one that survives a `remove`), the runner's
# own `.runner`, then the caller's fallback. The precedence lives in one place
# because its two callers disagree only about that last step — see each.
runner_named() {
  local name=""
  [ -r "$1/.rig-instance" ] && name="$(head -n1 "$1/.rig-instance")"
  [ -n "$name" ] || name="$(runner_agent_name "$1")"
  [ -n "$name" ] || name="$2"
  printf '%s' "$name"
}

# runner_instance_name <dir> — the name of the instance in <dir>, for LISTING.
#
# The directory name is the last resort: the legacy dir holding neither marker
# nor registration reads "actions-runner", which is honest in a listing — that
# box never told anyone a name, and the listing has to call the row something.
# It is NOT honest as a name to register with, which is why `install` resolves
# adoption through runner_named with the hostname default instead (#166).
runner_instance_name() {
  runner_named "$1" "$(basename "$1")"
}

# runner_instance_flag <base> <dir> — `managed` when rig put the install in
# <dir> there, `unmanaged` otherwise.
#
# Location under <base> is NOT the evidence, and treating it as such was the
# bug: anyone can mkdir <base>/mine and run config.sh in it — that is how boxes
# get concurrency today, it is the shape the systemd scan exists to surface,
# and calling it `managed` because of where it sits is the same untruth as
# `status` reporting one runner of four. `.rig-instance` is written when rig
# registers an instance, and again by `remove` before it tears one down, so it
# is the one thing on disk that means "rig put this here".
#
# The legacy <base> is the exception and stays `managed` unmarked. Every box
# installed before instances existed is that shape, none of them has the
# marker, and they are adopted in place — asking for it there would flag the
# entire installed fleet as somebody else's and refuse to converge it.
#
# `.rig-labels` is evidence too (#174 round 4). Only rig writes it, and it is
# the ONE artefact a pre-#166 install left: such a box is the legacy shape, so
# under the selected --user the exemption above already covers it — but the
# same box under ANOTHER service user is reached only by the systemd scan,
# where there is no base to be exempt by and no marker to find. Marker-only
# evidence printed `unmanaged` over one of rig's own installs there. It is
# weaker than the marker (a `remove` deletes it, keeping the marker on
# purpose), which is why it is the second question and never the first.
#
# No evidence is `unmanaged`, and that is deliberate: a directory named
# `actions-runner` under some home is NOT taken for rig's on its shape alone —
# location as evidence is the round 1 finding, and anyone can mkdir it. The
# first rig command run against that service user adopts it and marks it.
runner_instance_flag() {
  local base="$1" dir="$2"
  [ -n "$dir" ] || { printf 'unmanaged'; return 0; }
  if { [ -n "$base" ] && [ "$dir" = "$base" ]; } \
    || [ -r "$dir/.rig-instance" ] || [ -r "$dir/.rig-labels" ]; then
    printf 'managed'
  else
    printf 'unmanaged'
  fi
}

# runner_dir_in_base <base> <dir> — 0 when <dir> is a place rig's own layout
# puts an instance for THIS invocation: the legacy <base> itself, or one of its
# direct children.
#
# Ownership and reach are different questions, and conflating them was the
# second half of #174 round 4. `managed` says rig created the instance; it says
# nothing about whether the command in hand can act on it, because the base is
# a function of --user and the box has as many bases as it has service users.
# The verbs that BUILD in rig's layout — install, and repoint through it — need
# the second answer: install chowns BASE_DIR and RUNNER_DIR to its own
# --user, so running it over another user's tree re-owns that tree.
#
# One level, not a prefix match: <base>/<name> is the layout, and <base>/a/b is
# not somewhere rig puts anything.
runner_dir_in_base() {
  local base="$1" dir="$2" rest
  [ -n "$base" ] && [ -n "$dir" ] || return 1
  [ "$dir" != "$base" ] || return 0
  case "$dir" in "$base"/?*) rest="${dir#"$base"/}" ;; *) return 1 ;; esac
  case "$rest" in */*) return 1 ;; esac
  return 0
}

# runner_dir_owner <dir> — the user a directory belongs to, empty when rig
# cannot tell. The --user a refusal names has to come from the box, not from a
# guess: a cross-user refusal that cannot say which user is a dead end.
runner_dir_owner() {
  [ -n "$1" ] && [ -e "$1" ] || return 0
  stat -c '%U' "$1" 2>/dev/null || true
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
#
# The grep is wrapped because a box WITH systemd and no actions.runner.* unit
# is the ordinary empty box, and a grep that matches nothing exits 1 — which
# under the callers' `set -o pipefail` took the whole pipeline down with it and
# killed `remove`, `status` and `repoint` silently, exit 1 and not one line of
# output, on exactly the "nothing installed here" path they promise to
# converge on. Nothing found is an answer, not a failure. It survived the round
# because a review box has no systemd at all and returns above this line, and
# CI has none either; it took a fake systemd in the harness to see it (#174).
runner_scan_units() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local unit dir
  { systemctl list-units --all --no-legend --plain --type=service 'actions.runner.*' 2>/dev/null || true
    systemctl list-unit-files --no-legend --plain --type=service 'actions.runner.*' 2>/dev/null || true
  } | awk '{ print $1 }' | { grep -E '^actions\.runner\..*\.service$' || true; } | sort -u \
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
  local base="$1" units d n u f name dir unit
  units="$(cat)"
  local seen_dirs="" seen_units=""

  if [ -n "$base" ]; then
    for d in "$base" "$base"/*; do
      [ -d "$d" ] || continue
      runner_is_instance_dir "$d" || continue
      n="$(runner_instance_name "$d")"
      f="$(runner_instance_flag "$base" "$d")"
      u="$(runner_dir_unit "$d")"
      # A dir with no .service can still have a unit — one installed before rig
      # recorded it, or by hand. Ask the scan before giving up on it.
      [ -n "$u" ] || u="$(printf '%s' "$units" | awk -F'\t' -v dd="$d" '$2 == dd { print $1; exit }')"
      if [ -e "$d/.runner" ] || [ -n "$u" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$d" "$u" "$f" "live"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$d" "$u" "$f" "dormant"
      fi
      seen_dirs="${seen_dirs}${d}
"
      # The UNIT is remembered too, not just the directory. systemd's
      # WorkingDirectory for one of rig's own units can differ from the path
      # the walk arrived at by a single character — a symlinked home, a
      # trailing slash, a value it cannot report at all — and matching on the
      # directory alone then emits that instance twice, once `managed` from
      # here and once `unmanaged` from the scan. `status` double-counted it and
      # both selectors refused it as "more than one runner answers to <name>".
      [ -z "$u" ] || seen_units="${seen_units}${u}
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
    if [ -n "$dir" ] && printf '%s' "$seen_dirs" | grep -qxF "$dir"; then
      continue
    fi
    if printf '%s' "$seen_units" | grep -qxF "$unit"; then
      continue
    fi
    if [ -n "$dir" ] && [ -e "$dir/.runner" ]; then
      name="$(runner_instance_name "$dir")"
    else
      name="$(runner_unit_name "$unit")"
    fi
    # The flag is READ here, not assumed (#174 round 4). A scanned unit is one
    # rig's walk did not reach, which is not the same fact as one rig did not
    # create: the walk covers the selected --user's base, and a box running
    # rig's instances under two service users has the rest of them out here.
    # Hard-coding `unmanaged` printed "rig did not create this" over a
    # directory carrying rig's own marker — a false fact in the all-box view
    # `status` exists to make true, and it drove repoint's refusal to blame
    # ownership for what was really the wrong --user. Same evidence as the
    # walk, one function, so the two halves of the listing cannot disagree.
    #
    # No base is passed: the exemption in there is for the base of THIS
    # invocation, which by construction is not where we are.
    f="$(runner_instance_flag "" "$dir")"
    # Always live: a scanned unit IS a runner the box runs, whatever rig can
    # read of the directory behind it.
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$dir" "$unit" "$f" "live"
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
  local base="$1" name="$2" given="$3" instances="$4" line dir other

  # The one rule that reads the box rather than the name, and the whole of the
  # migration: a box whose runner lives in the legacy <base> layout keeps it.
  # Omitting --name there means "the runner this box already has", whatever it
  # is called — which is what omitting it meant before instances existed, so
  # such a box converges with the same dir, the same unit and no
  # re-registration. Pass a name and you get an instance, including beside it.
  #
  # runner_named with the CALLER's name as the fallback, not
  # runner_instance_name: adopting a legacy base that holds neither
  # `.rig-instance` nor `.runner` used to fall through to basename and register
  # the literal string "actions-runner" — as the config.sh --name argument, the
  # .rig-instance record, the name in the repo's Runners list and the unit
  # name — where AC2 says such a box converges on the hostname default. Two
  # pre-#166 boxes are in exactly that state: one that ran the documented
  # `remove` then `install` cycle under the old code, which wrote no marker,
  # and one whose first install had its config.sh fail on an expired token,
  # leaving the tarball unpacked and nothing registered. A box that DID record
  # a name still keeps it — that is the adoption, and it comes first.
  if [ "$given" -eq 0 ] && runner_is_instance_dir "$base"; then
    printf '%s\t%s\n' "$base" "$(runner_named "$base" "$name")"
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
    # ...and one rig DID create, under a different service user, is refused
    # here rather than adopted (#174 round 4). The listing reaches across the
    # whole box; install builds in one base and chowns BASE_DIR and RUNNER_DIR
    # to the --user it was given, so converging an instance that lives outside
    # this base would re-own another user's runner tree — the "looks like it
    # did the whole job" shape, from the other end. It is not a refusal to act:
    # it is a refusal to act as the wrong user, and it names the right one.
    #
    # The dir a scan reports for one of rig's OWN instances under this user can
    # differ from the walk's by a symlinked home; that instance lands here too,
    # and the refusal still names the directory and the user that owns it,
    # which is the pair the operator needs either way.
    dir="$(printf '%s' "$line" | cut -f2)"
    if ! runner_dir_in_base "$base" "$dir"; then
      other="$(runner_dir_owner "$dir")"
      printf 'rig-runner: ERROR: %s\n' \
"runner '${name}' lives at ${dir:-(directory unknown)}, outside ${base}:
$(runner_candidates "$line")
it belongs to another service user, and installing it from here would re-own
that runner's directory as this command's --user.${other:+
Re-run it against the user that owns it: --user ${other}}" >&2
      return 1
    fi
    printf '%s\t%s\n' "$dir" "$name"
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
  # ...and refusing an install that answers to a DIFFERENT name is the same
  # rule reached by the other door. The refusal above catches the name, this
  # one the DIRECTORY, and reaching here at all means the name matched no
  # instance on the box — so an install sitting at <base>/<name> is by
  # definition one that answers to something else.
  #
  # Two ways a box gets into that state, and the discriminator is the NAME, not
  # the marker (#174 round 3): <base>/mine registered by hand as `other` is
  # correctly refused as --name other (it is on the list, flagged unmanaged),
  # but --name mine falls through to here carrying no marker; and a
  # `repoint --rename old fresh` deliberately leaves the directory alone and
  # moves the identity, so <base>/old carries rig's own marker reading `fresh`
  # while the directory name `old` resolves to nothing. Testing for a missing
  # marker caught the first and walked straight into the second — rewriting a
  # live runner's identity record, skipping configure, and reporting a runner
  # "installed and running" that it had not created. Nothing is deregistered on
  # either path (assert_runner_repo catches a different repo first); what is
  # wrong is rig claiming a directory that already answers to someone.
  #
  # Which door each case goes through is worth being exact about (#174 round 4,
  # @claude-bot-andresmgsl): the hand-rolled `--name other` is refused UPSTREAM
  # by the `unmanaged` check, because the walk enumerated that instance — this
  # branch is not what catches it, and reading the two refusals as alternatives
  # for the same input would be wrong. What reaches here is a name that matched
  # NOTHING, which is why the question is about the directory. That leaves the
  # `other == name` fall-through unreachable from the CLI: a dormant
  # hand-rolled <base>/foo answering to `foo` is enumerated and refused by name
  # first. It stays, as the defensive floor on the one path where the upstream
  # guard has already said no such instance exists.
  if runner_is_instance_dir "$dir"; then
    other="$(runner_instance_name "$dir")"
    if [ "$other" != "$name" ]; then
      printf 'rig-runner: ERROR: %s\n' \
"${dir} already holds a runner that answers to '${other}', and registering
into it would adopt that one rather than create '${name}'. It is '${other}' to
every rig command, whatever its directory is called: pick another --name, or
take that runner down first." >&2
      return 1
    fi
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

# assert_runner_target <runner_dir> <repo|org> <target> <group> [instance_name]
#
# Returns 0 when the INSTANCE in <runner_dir> has no runner, or has one already
# registered to the same scope, target and (when recorded) organization group:
# real convergence re-uses the binary, skips registration, and exits 0.
#
# Returns 1, explaining itself on stderr, when the instance is registered to a
# DIFFERENT target. Skipping *that* is not convergence, it is ignoring the
# argument: `install` would skip its configure step, restart the service on the
# OLD target, and report success — leaving the target you asked for with no
# runner and its jobs queued against one that will never come. Moving a runner
# between scopes is a trust-boundary act, so it belongs to `repoint`, out loud.
#
# Scoped to one instance since #166: on a box running four, "this box's runner"
# named a thing that does not exist. The name is optional so the guard keeps
# working on a dir whose instance has no recorded name.
assert_runner_target() {
  local dir="$1" scope="$2" target="$3" group="$4" name="${5:-}"
  local current wanted subject select current_scope recorded_group target_words
  [ -e "$dir/.runner" ] || return 0

  current="$(runner_repo_url "$dir")"
  wanted="https://github.com/${target}"
  current_scope="$(runner_scope_from_url "$current")"
  recorded_group="$(runner_record_value "$dir" group)"
  if [ "$scope" = "org" ]; then
    target_words="organization ${target} (runner group ${group})"
  else
    target_words="repository ${target}"
  fi
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

  if [ "$current" = "$wanted" ] && [ "$current_scope" = "$scope" ]; then
    if [ "$scope" != "org" ] || [ -z "$recorded_group" ] || [ "$recorded_group" = "$group" ]; then
      return 0
    fi
    printf 'rig-runner: ERROR: %s\n' \
"${subject} is already registered to organization ${target} in runner group
${recorded_group}, not ${group}. install will not silently change which
workflows can reach it. Move it explicitly:
  rig runner repoint --org ${target} --runnergroup ${group}${select}" >&2
    return 1
  fi

  printf 'rig-runner: ERROR: %s\n' \
"${subject} is already registered to ${current} (${current_scope:-scope unknown}),
not ${wanted} (${target_words}). install will not move a runner across repository or
organization scope: it would leave the service running against the OLD target
and report success. To move it in one act:
  rig runner repoint --${scope} ${target}${select}
or take it off the old target first, then install:
  rig runner remove${select}             (deregisters from ${current}; needs a removal token)
  rig runner remove --local${select}     (when you cannot mint one)
To run a SECOND runner here instead of moving this one, give the new one its
own name:
  rig runner install --${scope} ${target} --name <name>" >&2
  return 1
}


# Backward-compatible sourceable helper used by the offline harness and by
# scripts outside this repository that adopted the old shared guard.
assert_runner_repo() {
  assert_runner_target "$1" repo "$2" "" "${3:-}"
}
