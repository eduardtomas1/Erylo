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
The resulting 12-way matrix runs every phase in a separate clean checkout. Each
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

Local measurements used Apple Swift 6.3.3 on an Apple silicon Mac. The original
548-check harness took 453.89s. The bounded/sharded `all` mode passed the same
548 checks in 370.85s with a 1.237GB maximum resident set; the
post-ownership-amendment confirmation passed in 375.35s with a 1.134GB maximum
resident set, the bounded-reap confirmation passed in 365.24s with a 1.249GB
maximum resident set, and the final arbitrary-exception confirmation passed in
371.98s with a 1.208GB maximum resident set.
The exact independent shard run was:

| Shard | Checks | Local wall time |
| --- | ---: | ---: |
| `source-boundaries` | 114 | 172s |
| `build-validation` | 43 | 44s |
| `private-symbols` | 25 | 67s |
| `bundle-default` | 19 | 41s |
| `bundle-ticket` | 5 | 41s |
| `updater-vectors` | 18 | 44s |
| `output-boundaries` | 10 | 43s |
| `archive-core` | 9 | 46s |
| `feed-vectors` | 150 | 59s |
| `key-vectors` | 35 | 47s |
| `evidence-boundaries` | 36 | 60s |
| `publication` | 84 | 77s |

The counts sum mechanically to 548. With the recovered operation timings,
`feed-vectors` has the longest relevant hosted critical path: staging 5m10s,
the base app assembly 3m40s, and overlapping capped validator waves with the
ready-vector assembly/validation path, estimated at about 14m20s. It therefore
uses the same 900-second hard command deadline as every other shard rather than
a larger blind timeout. Current-head hosted matrix URLs and actual durations
must still be recorded in the pull request before independent review.

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
