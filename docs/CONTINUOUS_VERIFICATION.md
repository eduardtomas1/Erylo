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
It runs the exhaustive deterministic release harness in its own job and runs
all Swift harnesses under AddressSanitizer and ThreadSanitizer in two other
jobs. Nightly jobs are diagnostic follow-up, not protected-branch status checks.
They have read-only source access and receive no signing, notarization, update,
or publication secrets.

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

As observed through the GitHub API on 2026-08-28, the repository had no ruleset
and `main` had no branch protection. After this workflow has produced its check
contexts, configure one active repository ruleset with:

- target: the default branch, currently `main`;
- bypass actors: none;
- pull requests required, with at least one approval, stale approvals dismissed,
  and all review conversations resolved;
- all checks listed under **Required pull-request checks** required, with the
  branch required to be up to date before merging;
- force pushes and branch deletion blocked; and
- linear history required.

Do not add the nightly sanitizer or deterministic-release jobs to the protected
branch ruleset. Do not replace the individual target contexts with the workflow
name: GitHub rulesets bind status checks by job context.

## Measured baseline and budgets

The failed monolithic design is recorded for diagnosis, not as current proof.
On commit `bfac2d36a9a269499d73ec944fb8c09953177fe7`, the main-branch run
<https://github.com/eduardtomas1/Erylo/actions/runs/33121614359> spent 60m10s in
the repository-owned CI step before the 60-minute job timeout cancelled it;
`Repository controls` completed successfully in 5s. Historical harness counts
or older green runs do not establish current-head correctness.

Local measurements used Apple Swift 6.3.3 on an Apple silicon Mac. The baseline
and final working tree have identical package and production sources; the final
tree adds only CI, documentation, scanner, and test-only TSan timing changes.

| Check | State | Wall time |
| --- | --- | ---: |
| Full warnings-as-errors build | Cold baseline | 40.36s |
| API-surface shard | Final clean scratch | 114.43s |
| Activity target shard | Final clean scratch | 19.27s |
| Media target shard, hostile inherited FD | Final clean scratch | 34.17s |
| Exhaustive deterministic release harness | Baseline | 462.12s |
| All Swift harnesses with AddressSanitizer | Final working tree | 27.28s |
| All Swift harnesses with ThreadSanitizer | Final working tree | 109.27s |

Local clean-scratch target measurements are capacity evidence only. The
14-minute hosted timeout is the hard per-shard ceiling; each pull request must
record current-head hosted job URLs and measured durations before independent
review.

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
bash Tests/ReleaseHarness/run.sh
```

The target and sanitizer arguments are allowlisted. Adding a test executable to
`Package.swift` requires updating the CI matrix, the shard allowlist, the
protected-main check list, and the canonical local entry point in the same
change.
