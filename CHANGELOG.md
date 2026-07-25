# Changelog

History before 0.1.0 lives in git — rig grew its version surface (`VERSION`,
`rig --version`, the side-by-side `versions/<v>` install layout; #35/#36)
on the way to cutting its first release, and this file starts there.

## 0.3.1 — 2026-07-24

### Added

- GitHub entry templates route humans to Discussions and prefill triage work orders and pull requests (#123)
- Platform, drill, docs and labels changes receive dedicated scope labels (#119)
- The `changelog-armed` guard returns, version-keyed (#112, ceremony#13)
- The `.ceremony/` doctrine mirror, verified by `docs-sync` on every PR (#112, ceremony#19)
- `rig template-lint` validates role definitions; rig-templates CI runs it on every PR (#110)
- Drill records cite the rig-templates SHA the converge read (#110)
- `kimi-box` joins the box tenant roles — the Kimi CLI agent guest (#109)
- CI drills the install lifecycle against a real tree — install from the checkout, converge to an empty diff, uninstall to proven absence (#106)
- `drill/drill.sh` — the drill has an instrument: pinned-ref assertion, a mechanical idempotence diff, and a `drills/<version>.md` record emitter (#105)
- `rig platform` prints a stable machine `ID`, derived from `/etc/machine-id`, never the raw value (#95)
- `rig bootstrap --undo` removes only a tailnet join rig can prove it made (#63)

### Changed

- Changelog entries land in per-issue fragments assembled by the release PR (#136)
- Release and labels machinery is consumed from heavy-duty/ceremony@0.1.0 by reference — the workflows shrink to caller stubs, the guard scripts and their tests move upstream (#112, ceremony#13)
- Agent-tenant definitions live in heavy-duty/rig-templates, pinned in-tree and overridable per mint (`RIG_TEMPLATES_DIR`/`_REF`/`_REPO`); the in-tree case arms are gone, `staging-box` stays (#110)
- `bootstrap --host yes` installs a pinned box release instead of `main` (#103)

### Fixed

- The quick-start fence names its channel and carries the release command beside it (#149)
- The drill's docs no longer claim both installers default to `main` — box installs the `BOX_RELEASE` pin, rig the latest release, and its `--box-ref` example is now a tag (#133)
- `kimi-bot-andresmgsl` is on the review panel — the roster predated it joining the bench (#120)

## 0.3.0 — 2026-07-21

### Fixed

- Deleting a shipped release heading from `CHANGELOG.md` is caught on every PR
  (#98, heavy-duty/box#122)
- The heading-uniqueness check no longer sits behind git conditions it does not
  need (#98, heavy-duty/box#143)
- An unreadable check rollup no longer reads as "nothing is failing" (#90)
- CI runs `test/labels-reconcile.sh`, which it had never run (#90)
- `state:needs-human` no longer appears on PRs a human cannot merge
  (#87, heavy-duty/box#136)
- A missing `/run/sshd` no longer reads as a broken sshd config (#92)
- CI's shellcheck sweep reaches `.github/scripts/` (#70)
- Ctrl-D at the `rig uninstall` confirm aborts out loud (#68)
- `users apply` tells "revoke everyone" apart from a truncated users file (#65)

### Added

- CI refuses a release PR with no drill record at `drills/<version>.md`
- `rig platform` — what this machine is, computed at run time, stored nowhere
  (#64)
- `/etc/rig/manifest` records which rig converged a machine, and when (#61)

### Changed

- `state:needs-human` is set at handoff, not by the cron (#96)
- PR labels split into two axes: `state:*` (whose ball) and `blocker:*` (what
  is in the way) (heavy-duty/box#137)
- BREAKING: `--class human|server` is now `--root-door closed|open`; old
  markers still resolve (#77)
- BREAKING: the box tenant roles carry a `-box` suffix (#76)
- BREAKING: machine roles carry a `-server` suffix, and `staging-server` is
  back (#76)
- Changelog entries are one line each, and the whole file now follows the rule
  (#100)

## 0.2.0 — 2026-07-19

### Added

- `users apply` grants the box *tier*, not just its socket (#49)

### Changed

- BREAKING: `rig bootstrap` takes the users file, and requires it (#51)

### Fixed

- A release no longer disarms the changelog under the PRs still in flight (#67)
- A `host=no` box with an `incus` group no longer hands out the bare socket
  (#58)
- Dropping the box role revokes through `box`, not behind its back (#50)
- `rig bootstrap` refuses a users file that names no users (#57)

## 0.1.0 — 2026-07-19

### Fixed

- The release suite accepts the ceremony's own tree (#44)
- The installer survives an environment with no `$HOME` (#39, #41)
- Headless credential prompts refuse loudly instead of dying silently (#42)

### Added

- Merging a release-labeled PR IS the release, and the release re-arms main
  (#47)
- Tagged releases, and an installer that installs them (#32)
