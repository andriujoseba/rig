# The drill — running it

`drill/drill.sh` is the instrument; `drills/` is the record it feeds
(see [drills/README.md](../drills/README.md) for what a record means and
how the three repos' drills relate). rig's drill asserts **convergence**:
a machine reaches its role, idempotently. This file is the procedure —
written down so a run is repeatable, not reconstructed from memory each
release (#105, and #107's debt).

## What you need

- **A throwaway Debian 13 machine** you can format, reached as root, with
  `curl`. A VM is fine; a container is not, because this drill converges an
  Incus host. One known-good substrate is a fresh box VM:

  ```sh
  box new --name drill-rig --vm --cpu 4 --memory 8GiB --disk 60GiB
  ```

  Do not use `staging-box`: it is a VM-only, autostarting server seed rather
  than a disposable scratch mint. The box the drill installs carries the
  nested-network subnet selection `box doctor` needs inside a box VM
  (box#80); `--box-ref` selects it, defaulting to the candidate tree's
  `BOX_RELEASE` pin. The drill hardens sshd, renames the machine, joins it to
  a tailnet, and installs box/Incus and Docker. The machine is its own reset;
  there is no teardown.
- **The pinned candidate refs, both of them.** `--rig-ref` and
  `--box-ref` are required; the harness refuses to run without them and
  refuses to continue if what installed disagrees with what was asked
  (`INSTALLED_FROM`, both trees). Since heavy-duty/rig#103 landed, both
  installers have sane defaults when unpinned — box installs the candidate
  rig tree's `BOX_RELEASE` pin, rig's `install.sh` resolves the latest
  release — and a sane default is exactly why the drill will not
  let a ref go unstated: an unpinned run silently drills a shipping pair
  that is not the candidate, and the record it leaves looks clean.
- **A branch or tag GitHub can serve.** `--rig-ref refs/pull/N/head` is not
  one: raw and archive URLs do not resolve PR refs. Push the candidate to a
  branch on a fork, use that fork as both the raw URL and `--rig-repo`, and
  pass the branch name to `--rig-ref`.
- **A single-use, tagged tailscale pre-auth key** in `TS_AUTHKEY`
  (`tag:local` for the default `staging-server` role — bootstrap refuses
  `tag:server` outside the control-plane shapes).
- **Exactly one operator source.** `--users-from-github <handle>` fetches
  `https://github.com/<handle>.keys` and writes one `admin,box` ledger line
  per public key; the handle must also be a valid lowercase rig username.
  Use `--users <path>` instead for multiple operators or different roles.
  Leg 1 asserts that at least one operator, account and key converged.
- **A run ID** (`--run-id`) when this drill shares a substrate with
  box's or cast's — the shared ID is what lets the per-repo records be
  joined afterwards. Defaults to `drill-<date>`.
- **A direct root entry path.** If the shell carries `SUDO_USER`, that user
  must be in `rig-admin`. In particular, `box shell` preserves a non-admin
  `SUDO_USER` and will be refused before the tailnet key is spent. Enter a
  box VM with `incus exec <box> -- bash -l`, or `unset SUDO_USER` in a root
  shell, before starting.

## Running it

No checkout is needed. Serve the instrument and the candidate from the same
repo/ref pair:

```sh
RIG_REPO=heavy-duty/rig
RIG_REF=release/0.4.0
TS_AUTHKEY=tskey-... bash <(curl -fsSL \
  "https://raw.githubusercontent.com/$RIG_REPO/$RIG_REF/drill/drill.sh") \
  --rig-repo "$RIG_REPO" --rig-ref "$RIG_REF" --box-ref 0.10.0 \
  --users-from-github danmt --run-id drill-2026-08-26-a --yes
```

`--box-ref` is a tag on purpose: since #103 the box that ships is the
`BOX_RELEASE` tag, so a `release/…` branch is the wrong thing to pin for
box — while a release branch stays exactly right for rig's own candidate.

It runs unattended from there. Legs execute as 1, 2. Before leg 2 the drill
installs Debian's Docker package directly, so a pristine machine supplies a
real daemon for the database round-trip. The record lists legs as they ran.
A failing check never aborts the
run (`set -u`, no `-e`: a failing check is data), and the summary counts
passes, failures and skips separately.

## What it asserts

1. **Convergence, and idempotence.** `rig bootstrap <role> --users …`
   reaches the declared role, asserted on *effective* state — the marker,
   `sshd -T`, the granted tailnet tag, the operators' accounts and keys.
   Then bootstrap runs **again**, and the state captured before and after
   the re-run must diff **empty**. The diff is mechanical; "watched it
   not obviously break" is exactly what this leg exists to replace.
   Riding along, the `--host yes` assertions: the **pinned** box
   installed (`INSTALLED_FROM` matches `--box-ref`, fatal if not),
   `box doctor` passes. It stops there and says so in the output — the
   isolation boundary is **box's** drill's assertion, never rig's.
2. **db** — `test/db-integration.sh` from the *installed* tree: a real
   dump/restore round-trip, after the drill installs Docker directly. The
   script's clean-skip contract (no Docker → loud skip, exit 0) remains the
   classifier's tiebreaker and survives into the record as a SKIP, never a
   pass, if Docker provisioning did not leave a daemon.

## Who runs it, and where the record goes

The builder runs the drill when they can reach a genuine fresh Debian host or
VM. If their environment cannot — including a builder session already inside
a box — the operator runs it instead. An operator pastes the complete final
stdout into a comment on the release issue. The builder copies that evidence
verbatim into `drills/<version>.md` on the release branch; the issue comment is
the attributed handoff, and the committed file is what the guard reads.

## The record

The run always ends by writing `/root/drills/<version>.md` (the version is
the installed tree's own `VERSION`), printing that path, and echoing the full
record to stdout. That happens on failures too: **a failed drill is a valid
record**; the gate wants evidence, not success. Skipped legs are named as
not-run so the record can never read as a clean sweep. Commit the file as
`drills/<version>.md` on the release branch; the `drill-recorded` guard reads
that file and nothing else. `--record <path>` overrides the local output path.

The instrument's own honesty — the refusals, the skip accounting, the
capture-and-diff, the emitter — is `test/drill.sh`'s job, and CI runs it
on every PR. The live two-leg run is a release's job, once per cycle.
