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

`Swift build` preserves the warnings-as-errors contract across every product.
`API surface` preserves both repository-owned public-surface checks. Each test
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
set as the executable harness phases and that their expected counts sum to 548.
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

Current-topology local measurements used Apple Swift 6.3.3 on an Apple silicon
Mac. Every row below is a separate isolated shard invocation with a clean
fixture root and a clean warnings-as-errors Swift scratch directory where the
concern requires compiled artifacts:

| Shard | Checks | Local wall time |
| --- | ---: | ---: |
| `source-boundaries` | 114 | 170.32s |
| `build-validation` | 34 | 4.41s |
| `build-artifact` | 6 | 33.85s |
| `symbol-validation` | 3 | 32.93s |
| `private-symbols` | 2 | 33.85s |
| `private-evidence` | 23 | 25.05s |
| `bundle-default` | 19 | 35.07s |
| `bundle-ticket` | 5 | 33.69s |
| `updater-vectors` | 18 | 36.48s |
| `output-boundaries` | 10 | 1.77s |
| `archive-core` | 9 | 37.84s |
| `feed-vectors` | 150 | 49.16s |
| `key-vectors` | 35 | 39.60s |
| `evidence-boundaries` | 14 | 4.80s |
| `archive-evidence` | 4 | 39.50s |
| `release-cleanup` | 18 | 5.55s |
| `publication` | 84 | 37.06s |

The composed `all` mode then passed the same 548 checks in 310.64s with a
1.221GB maximum resident set. The counts sum mechanically to 548.
`source-boundaries` is the longest local shard at 170.32s; among compiled
release concerns, `feed-vectors` is longest at 49.16s. These local results
demonstrate topology and substantial local margin,
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
