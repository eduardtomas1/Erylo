# Continuous verification contract

## Required pull-request checks

`continuous-verification.yml` runs for pull requests, pushes to `main`, and
manual dispatches. GitHub begins with no token permissions; each job grants only
read-only `contents` access for checkout, and checkout never persists its
credential. Every third-party action is pinned to a full commit SHA with its
human-readable release in a comment.

The repository-control job also runs adversarial scanner regressions. Tracked
binary blobs are scanned rather than skipped, scanner errors fail closed, and
only sanitized filenames can be logged. Coverage includes NUL-prefixed blob
content, private-key markers, current `github_pat_` credentials, and filenames
containing control characters and token-shaped text.

The required checks are intentionally independent and every required job has a
timeout below 15 minutes:

- `Repository controls`
- `Swift build`
- `API surface`
- `PR target / EryloActivityTests`
- `PR target / EryloFoundationTests`
- `PR target / EryloFileHoldTests`
- `PR target / EryloGlanceTests`
- `PR target / EryloMediaTests`
- `PR target / EryloTrustTests`
- `PR target / EryloIntegrationTests`
- `PR target / EryloSurfaceTests`
- `PR target / EryloUpdateTests`
- `PR target / EryloAppRuntimeTests`

`Repository controls` remains Linux-portable and owns repository hygiene plus
scanner regressions. `Swift build` preserves the warnings-as-errors contract
across every product. The required macOS `API surface` job additionally proves
that the SwiftPM-derived shipping source closure equals the compiler-input policy
and runs compiler-syntax permission validation. It also preserves all three
repository-owned public-surface checks, including independent package-access
probes for every Battery/Volume composition type and a closed provider scan
across the complete app-runtime source set. Each test
target gets its own cold checkout and build so one slow or stuck harness cannot
consume the entire pull-request verification window. Target compilation uses
two workers, then exits SwiftPM before launching the built executable so the
hosted runner does not retain compiler memory during the harness. The launcher
also closes runner-control descriptors 3 through 255 before execution. This
gives the media harness's low-descriptor isolation check a stdio-only parent,
while preserving its checks for descriptors leaked by the Erylo child-process
implementation.

The package contract is unchanged: Swift tools 6.0, Swift language mode 6, and
macOS 14 deployment. The macOS jobs use `macos-15` because the public
`macos-14` runner's default Swift toolchain does not satisfy the Swift 6
contract.

## Nightly and release separation

`nightly-verification.yml` runs daily at 03:17 UTC and supports manual dispatch.
It proves that the release-shard manifest is the same ordered, duplicate-free
set as the executable harness phases and that their expected counts sum to 593.
The resulting 17-way matrix runs every phase in a separate clean checkout. Each
release shard has a 900-second command deadline inside a 17-minute job deadline;
the outer owner reports the exact timeout/cancellation classification and uses
the remaining job time to TERM, KILL if needed, reap its direct child exactly
once, and prove whole-process-group settlement. The sanitizer matrix still runs
all Swift harnesses under AddressSanitizer and ThreadSanitizer.

Metadata-heavy assertions run through an owned batch capped at 12 live helper
owners. Throttling reports queued, active, started, and reaped counts, and batch
completion reports peak active (admitted but unreaped) owners. The focused
regression separately measures physical child concurrency. The cap permits
independent validators to overlap without creating an unbounded hosted
process/FD load.

The full production build and staging operation belongs only to
`build-artifact`, whose assertions inspect that artifact. Bundle and vector
shards instead compile the real arm64 release product with warnings as errors,
retain the real Sparkle framework and selected-toolchain binding, and assemble
only the bundle they validate. Metadata, cleanup, and publication shards use
structural fixtures only where their assertions do not inspect executable
contents. The contract checker locks those ownership boundaries. Archive
equivalence is not assumed: the extracted application is validated and then
compared with the staged application by exact entry type, mode, link target,
and byte digest; private symbols similarly validate the source dSYM and prove
the extracted archive has the exact same manifest.

Nightly jobs are diagnostic follow-up, not protected-branch status checks. They
have read-only source access and receive no signing, notarization, update, or
publication secrets.

ThreadSanitizer adds more than two seconds to each self-spawned media-helper
process on the measured Mac. Its build therefore enables a test-only compile
condition that widens functional helper deadlines and keeps the post-exit bound
below the ten-second failure threshold. It also widens only the harness polling
window needed to observe instrumented descendant cleanup. Production media
limits and behavior are unchanged.

Release signing, notarization, stapling, archive validation, and publication
remain separate operator gates in `docs/RELEASE_RUNBOOK.md`. A green nightly
run is not release authorization and does not replace hardware or notarization
evidence.

## Protected `main` ruleset

As observed through the GitHub API on 2026-08-28, the active repository ruleset
`Protect main — reviewed, green, linear` targets the default branch and has no
bypass actors. It requires a pull request, dismissal of stale reviews, resolution
of review conversations, and zero approvals so the repository owner is not
blocked by a self-impossible approval. It permits squash merge only, requires
strict success from all 13 checks listed under **Required pull-request checks**,
requires linear history, and blocks force pushes and deletion.

Do not add the nightly sanitizer or deterministic-release jobs to the protected
branch ruleset. Do not replace the individual target contexts with the workflow
name: GitHub rulesets bind status checks by job context.

## Measured baseline and budgets

The failed monolithic hosted design is diagnostic evidence, not success. On
exact head `8d095bae075417c07cc844e79b1720a56bfe9516`, nightly
[run 33155546665](https://github.com/eduardtomas1/Erylo/actions/runs/33155546665)
had green AddressSanitizer (1m27s) and ThreadSanitizer (3m24s) jobs. Its
[release job 98797333160](https://github.com/eduardtomas1/Erylo/actions/runs/33155546665/job/98797333160)
was manually cancelled after 1h0m48s. The recovered log proves forward progress:
production staging at 08:41 UTC, dSYM validation at 08:44, private archives by
09:01, default validation at 09:06, post-staple validation at 09:18, updater
validation at 09:27, and cancellation at 09:31 with `codesign` still active.

The equivalent updater milestone took 231.90s locally and 3402.46s hosted, a
14.67x multiplier. Compilation itself was 28.92s hosted versus 31.35s local;
the multiplier came from metadata, archive, and signing operations. For example,
post-build staging was 309.47s hosted versus 2.40s local, dSYM validation was
182.56s versus 0.918s, and the two serial private archives took 546.33s and
434.69s hosted versus 4.14s and 3.07s locally. Shard design therefore follows
expensive operations rather than check counts: repeated archives are concurrent,
metadata validations are capped batches, and each shard constructs only the
fixtures its assertions require.

The first exact-main shard run is also failure evidence, not a green baseline.
On exact `6e58c0406b20a3f319f8bb930fef2b43d6218c1b`, nightly
[run 33173330593](https://github.com/eduardtomas1/Erylo/actions/runs/33173330593)
passed the contract, both sanitizers, publication, and `bundle-default`.
`bundle-default` nevertheless took 13m53s of job wall time. Nine shards reached
their owned 900-second command deadline and settled cleanly:
`output-boundaries`, `private-symbols`, `archive-core`, `key-vectors`,
`feed-vectors`, `updater-vectors`, `bundle-ticket`, `evidence-boundaries`, and
`build-validation`. `source-boundaries` failed because a deliberate split write
used a scheduler-dependent 30ms delay inside an 80ms readiness window. The
replacement test uses explicit writer and reader gates to prove that an
incomplete prefix is not readiness, while a separate case retains exact missed-
readiness timeout coverage. Production timeout values are unchanged.

The first hosted run of the 17-shard topology is further failure evidence, not
a green baseline. On exact `b9e56f428af98b99908f5fa831a957cf9d52b036`,
nightly [run 33182298163](https://github.com/eduardtomas1/Erylo/actions/runs/33182298163)
passed the contract, both sanitizers, and 15 of 17 release shards. Hosted shard
wall times were: `build-validation` 23s, `private-evidence` 44s,
`evidence-boundaries` 28s, `output-boundaries` 16s, `source-boundaries` 5m15s,
`private-symbols` 6m17s, `bundle-ticket` 6m04s, `bundle-default` 7m43s,
`updater-vectors` 11m45s, `release-cleanup` 10m52s, `archive-core` 9m56s,
`build-artifact` 8m40s, `symbol-validation` 7m38s, `archive-evidence` 11m06s,
and `publication` 1m15s. `feed-vectors` reached its owned deadline in
[job 98886359148](https://github.com/eduardtomas1/Erylo/actions/runs/33182298163/job/98886359148),
settled its owned process group, and exited 124 after 15m11s of job wall time
and 901.579s of owned command time. `key-vectors` completed in 10m53s in
[job 98886359282](https://github.com/eduardtomas1/Erylo/actions/runs/33182298163/job/98886359282)
but failed 9 of 35 assertions.

That run exposed one isolated-fixture routing defect rather than invalid vector
semantics. The counted canonical appcast values matched the updater fixture that
had just assembled successfully, but vector assemblers omitted the compiled
fixture arguments and therefore looked for absent production defaults under
`.release/build`. Update signing likewise looked for default staged tools before
reaching the appcast diagnostic or full-Xcode boundary. Meanwhile malformed
bundle vectors paid almost the complete validator path before rejection. The
amendment binds every isolated vector assembler to the real warnings-as-errors
compiled fixture, validates signed appcast metadata before unrelated artifact
work, and reuses the counted canonical assembly as the updater fixture. The
17-shard, 548-check union and both timeout levels remained unchanged. Exact-SHA
hosted proof was still required because local timing cannot substitute for it.

The next exact-SHA nightly exposed one remaining shared-parent race rather than
a shard-topology failure. On exact
`89231cd039470a2bbd6ddcf88bb997be6b7b7d9e`, nightly
[run 33188560029](https://github.com/eduardtomas1/Erylo/actions/runs/33188560029)
passed the contract, both sanitizers, and 16 of 17 release shards. Hosted shard
wall times were: `bundle-ticket` 6m18s, `updater-vectors` 7m31s,
`bundle-default` 6m15s, `source-boundaries` 3m56s, `build-artifact` 10m02s,
`archive-evidence` 14m24s, `output-boundaries` 23s, `archive-core` 11m59s,
`key-vectors` 8m09s, `build-validation` 22s, `symbol-validation` 9m25s,
`feed-vectors` 13m19s, `publication` 1m18s, `evidence-boundaries` 31s,
`release-cleanup` 10m25s, and `private-evidence` 47s. The sole failure,
[`private-symbols`](https://github.com/eduardtomas1/Erylo/actions/runs/33188560029/job/98907861455),
completed its product build in 33.48s, then two concurrent symbol archivers both
observed a missing descriptor-anchored `tmp` parent. One creator won; the other
reported fatal `EEXIST`, while its peer reported `ENOENT` reopening `tmp`.

The filesystem amendment uses the existing `mkdirat` allow-exists result at
both descriptor-anchored parent-creation sites, then immediately reopens the
observed child with `O_DIRECTORY|O_NOFOLLOW` and applies the existing ownership
and 0700-mode validation. It adds no retry loop or tolerance for a symlink,
wrong owner, wrong type, or failed reopen. A test-only gate releases two real
helpers only after both report the same missing `tmp`; the existing counted
filesystem assertion proves distinct 0700 children under one real 0700 parent,
no external writes, and safe anchored cleanup. The existing parent-swap and
symlink fail-closed assertions remain alongside it.

The same hosted run also showed that green was not sufficient for
[`archive-evidence`](https://github.com/eduardtomas1/Erylo/actions/runs/33188560029/job/98907861499):
its phase completed at elapsed 840s, leaving only 60s of the owned command
budget. The exact log records default app assembly at 16:14:20, an uncounted
default archive creation plus its internal validation completing at 16:16:36,
the counted post-staple validation at 16:20:59, and a second validation used
only for the predictable-path symlink assertion before phase completion at
16:23:13. The amendment removes that uncounted archive and combines the planted
symlink defense with the already-counted post-staple validation. Separate
counted assertions still prove that the planted symlink and its external target
are unchanged; pre-staple rejection, post-staple acceptance, archive production,
and extracted-app equivalence remain covered. This removes about 4m29s of work
measured directly in the hosted critical path without relaxing either timeout.
Exact-SHA hosted proof of the resulting commit is pending.

Current-topology local measurements used Apple Swift 6.3.3 on an Apple silicon
Mac. Every row below is a separate isolated shard invocation with a clean
fixture root and a clean warnings-as-errors Swift scratch directory where the
concern requires compiled artifacts:

| Shard | Checks | Local wall time |
| --- | ---: | ---: |
| `source-boundaries` | 114 | 163s |
| `build-validation` | 34 | 6s |
| `build-artifact` | 6 | 34s |
| `symbol-validation` | 3 | 32s |
| `private-symbols` | 2 | 37s |
| `private-evidence` | 23 | 26s |
| `bundle-default` | 19 | 48s |
| `bundle-ticket` | 5 | 50s |
| `updater-vectors` | 18 | 46s |
| `output-boundaries` | 10 | 4s |
| `archive-core` | 9 | 73s |
| `feed-vectors` | 150 | 57s |
| `key-vectors` | 35 | 68s |
| `evidence-boundaries` | 14 | 7s |
| `archive-evidence` | 4 | 41s |
| `release-cleanup` | 18 | 6s |
| `publication` | 84 | 40s |

The composed `all` mode then passed the same 548 checks in 371.71s with a
1,137,065,984-byte maximum resident set. The counts sum mechanically to 548.
The deterministic two-creator filesystem regression also passed ten consecutive
34-check `build-validation` runs in 5–6s each, and the process-supervisor suite
passed five consecutive 67-check runs in 13–14s each. `source-boundaries` is the
longest local shard at 163s; among compiled release concerns, `archive-core` is
longest at 73s. These
local results demonstrate topology and substantial local margin,
not hosted success: the earlier 14.67x metadata-operation multiplier makes
hosted inference unsafe. An exact-SHA hosted matrix and its actual durations
must therefore be recorded before independent review. Every shard retains the
same 900-second hard command deadline rather than masking fixture cost with a
larger timeout.

## Exact-SHA evidence

The complete implementation is bound to immutable hosted and local evidence in
[`01334df958b389426ed6e5d73fa7f336e7ac861e.md`](verification-evidence/01334df958b389426ed6e5d73fa7f336e7ac861e.md).
Because checking in that evidence changes the commit hash, the evidence file
also defines the permitted documentation-only delta, while the pull-request
body records the final review head and its separate current-head hosted run.

## Local entry points

`Scripts/ci.sh` remains the complete canonical local entry point. For focused
CI reproduction, use:

```sh
.github/scripts/check-repository.sh
.github/scripts/test-check-repository.sh
.github/scripts/run-ci-shard.sh build
.github/scripts/run-ci-shard.sh api-surface
.github/scripts/run-ci-shard.sh target EryloActivityTests
.github/scripts/run-ci-shard.sh sanitizer address
/usr/bin/ruby Tests/ReleaseHarness/check-shards.rb
.github/scripts/run-release-harness-shard.sh source-boundaries 114 900
bash Tests/ReleaseHarness/run.sh
```

The target and sanitizer arguments are allowlisted. Adding a test executable to
`Package.swift` requires updating the CI matrix, the shard allowlist, the
protected-main check list, and the canonical local entry point in the same
change.
