# Contributing

This repo is governed by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony). **Agents:
read [`.ceremony/AGENTS.md`](.ceremony/AGENTS.md) first** — it routes you to
your role file (builder, reviewer, triage), vendored beside it,
byte-identical to ceremony at the pin named in
[`.github/workflows/release.yml`](.github/workflows/release.yml) and
guarded by the `docs-sync` step in CI. The review-round doctrine — drafts,
whole-round replies, verdicts, the handoff — lives there and in
[`.ceremony/LABELS.md`](.ceremony/LABELS.md); this file keeps only what is
genuinely rig's.

## The PR loop, rig specifics

1. **Fork and branch.** Contributors work from forks; upstream branches are
   for maintainers. Title the PR conventionally (`feat:`, `fix:`, `docs:`).
2. **The review panel.** [`.github/labels.conf`](.github/labels.conf) is the
   governing roster: use `panel[<your-login>]=` when that row exists,
   otherwise `panel=`, then remove the author. In rig the builder marks the
   PR ready, waits for a green head, and requests that resolved panel. The
   labels workflow requests no panelist; its only reviewer request is the
   human at handoff ([reconciler](https://github.com/heavy-duty/ceremony/blob/c64e06689356204c24dd1de35c505b0508070453/actions/labels-reconcile/labels-reconcile.sh#L930-L932)).
   This is rig's answer to BUILDER.md's conditional
   [engine-mediated request rule](.ceremony/BUILDER.md#the-review-round).
   The maintainer (`danmt`) takes the last word and merges.
3. **Checks must be green**: `shellcheck`, `bash test/cli.sh` and
   `bash test/release.sh` locally mirror what CI runs; the db dump/restore
   round-trip (`test/db-integration.sh`) executes in CI where Docker is
   present. The release guards (`changelog-armed`, `changelog-monotonic`,
   `changelog-assembled`, `drill-recorded`, `runner-isolated`, `docs-sync`)
   run as ceremony's pinned actions.
4. **Feature PRs land their changelog entry as part of the PR**: write
   `changelog.d/<issue>.md` — the release PR assembles those fragments into
   the release notes verbatim.
5. **An issue whose criteria outlive the merge is referenced, never closed**:
   such a PR says `Refs #N`, and `refs-guard` now says so instead of a human
   catching it — it reds when a body promising `Refs #N` contradicts GitHub's
   closing-issue graph, on the body **edit** as much as on a push.
6. **A red head you cannot rerun is asked for, not waited on**: every build PR
   here is a fork PR, so its run lives in this repository and only `actions:
   write` here can restart it. Comment the evidence — `🔁 rerun owed at head
   <full-sha>` — and set `rerun-owed`; `ci-rerun` starts the one rerun, clears
   the label and comments the new attempt. A refusal leaves the label standing
   and names the gate that refused, the roster in `.github/labels.conf` being
   the first of them.

## Changelog entries

Every PR that changes behaviour writes one `changelog.d/<issue>.md` fragment.
The fragment keeps the relevant `### Added` / `### Changed` / `### Fixed`
heading above its entry. One line is the whole rule — if it wraps more than
twice in your editor, cut it down.

- **Say what changed, and stop.** Why it was wrong, how it was found, what it
  cost, what it implies — that belongs in the PR body and the commit message,
  which is where anyone chasing the reasoning already goes. This file answers
  one question: what is different in this version.
- **Any word that can be removed, is removed.**
- **Lead with the surface, not the mechanism.** "`state:needs-human` is set at
  handoff" beats "the labels workflow now also wakes on `labeled`".
- **Cite the issue or PR** — `(#96)` — and let the reader follow it for the
  rest.
- **Mark a breaking change** with a leading `BREAKING:`.
- Group under `### Added` / `### Changed` / `### Fixed` / `### Removed`.
- No bold run-in headings, no sub-paragraphs, no code blocks, no prose essays.

Good:

- `state:needs-human` is set at handoff, not by the cron (#96)
- An unreadable check rollup no longer reads as "nothing is failing" (#90)
- BREAKING: `--class human|server` is now `--root-door closed|open` (#77)

Not an entry — that is a PR body:

- **`state:needs-human` no longer waits on the cron to become true** (#96) —
  the labels workflow now also wakes on `pull_request_target: labeled` and
  `unlabeled`, and the author sets it themselves when handing a PR over. A
  review landing was never a trigger. There is no `pull_request_review_target`,
  and on fork PRs — which is all of them here — ...

## Releasing

A release is a PR, and merging it is the release. The ceremony — the two
doors, the decide table, the stamps, the post-release re-arm — is
heavy-duty/ceremony's machinery, consumed by reference:
[its README](https://github.com/heavy-duty/ceremony/blob/main/README.md)
is the doctrine, `.github/workflows/release.yml` here is the ≤20-line
caller pinning it, and the guards run in `ci.yml` from the same pin.
Bare `X.Y.Z` tags, no `v`; the tag's source tarball is the package
`install.sh` downloads — rig ships no other artifact. Each release deliberately
bumps and drills the `BOX_RELEASE` pin in `commands/bootstrap.sh`; it must never
float to a moving ref.

What stays rig's is the **drill** — the real-hardware gate before the
handoff of a release PR, run by `drill/drill.sh` (#105): `rig bootstrap`
converging the machine to its role twice with the second run diffed empty,
installing Docker directly, and running `test/db-integration.sh`. Rig's drill asserts
**convergence** (a machine reaches its role,
idempotently), it runs `--host yes` with `BOX_REF=release/<box-version>` so
it exercises the box that will actually ship, and drills that share a
substrate share **one run ID** so the per-repo records can be joined after
the fact. The full meaning — the fixed candidate-ref pinning that dissolves
the box↔rig recursion, the per-version record files, the waiver rule — is
[`drills/README.md`](drills/README.md); the `drill-recorded` guard enforces
the record on every release tree.

The builder runs the drill when they have a genuine fresh Debian host or VM;
otherwise the operator runs it. An operator posts the instrument's complete
final stdout on the release issue, and the builder copies that attributed
record into `drills/<version>.md` on the release branch. A builder session
already inside a box never runs the host drill there.

## Labels — who sets what

The taxonomy and state machine are
[`.ceremony/LABELS.md`](.ceremony/LABELS.md); rig's `scope:*` rows live in
`.github/labels.conf` (reconciled by the labels caller) and their path map
in `.github/labeler.yml`. What matters day to day is who sets each kind —
most of it is machinery, and hand-moving a machine-owned label just gets
corrected on the next pass:

| Labels | Set by |
|---|---|
| `state:*` | the labels workflows ([.github/workflows/labels.yml](.github/workflows/labels.yml), [`.github/workflows/labels-sweep.yml`](.github/workflows/labels-sweep.yml)) — event-triggered reconciliation is dispatched in seconds, with an hourly sweep for transitions that have no event wake. Machine-owned, with one exception: the author sets `state:needs-human` at handoff and the workflow reconciles it. Otherwise never by hand. Exactly one per PR: *whose ball is it.* |
| `blocker:*` | the same workflow, from the same facts — *what is in the way.* Any number per PR, or none. Never by hand: applying one does not stop a merge, and removing one does not unblock anything. Fix the thing and the next sweep drops the label; for `blocker:unrequested`, the thing is the missing panel request and the builder owes that act. |
| `stale` | the same workflow — 48h without commits, comments, or reviews. `blocked` PRs are exempt: they are quiet legitimately. |
| `scope:*` on PRs | actions/labeler, from the changed paths ([.github/labeler.yml](.github/labeler.yml)). Additive — you may add more, the machine won't remove them. |
| `scope:*` on issues | you, when opening or triaging — issues have no paths to derive from. |
| `blocked`, `release` | you — automation never guesses intent. |
| `rerun-owed` | the builder, beside the evidence comment naming the head. Only a **started** rerun clears it: `ci-rerun` removes it on success and leaves it standing on a refusal, so the label is the ask and its absence the answer. |
| `merge-next` | you or the agent owning the queue. Which PR lands first is a judgement about how they conflict, so the workflow never sets it — it only **clears** it, the moment the PR stops being something a human could merge. |
| `bug` / `enhancement` / `documentation` | you, on issues only — a PR's type already lives in its title. |

## Issues

Give issues the same care as PR titles: say the surface in the title, apply a
`scope:` label and a type label (`bug` / `enhancement` / `documentation`) when
you open one, and `blocked` when it waits on something — that is what keeps
the board navigable as the issue count grows.
