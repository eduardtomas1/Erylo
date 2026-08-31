# Hidden-surface idle resource proxy

This change uses deterministic lifecycle counters as a reproducible allocation
and callback-registration proxy. It does not claim Instruments, hardware energy,
or sampled CPU evidence.

## Reproduction

Reference baseline: exact `main` commit
`99322dc32eecf440c3a91ec381e5b7a59b5e5b45`.

```sh
swift build -Xswiftc -warnings-as-errors
swift run --skip-build EryloFoundationTests
swift run --skip-build EryloSurfaceTests
```

The Foundation harness uses two enabled, non-mirrored displays plus one duplicate
and one mirrored display. The Surface harness inspects the system lifecycle
source's native-resource probe and its bounded pointer-delivery scheduler.

| Idle/reveal resource proxy | Baseline | This change |
| --- | ---: | ---: |
| Panel factory calls after default startup | 2 | 0 |
| Native pointer monitors after lifecycle-source startup | 2 | 0 |
| Display/Space/sleep-wake observers retained while idle | 4 | 4 |
| Panel factory calls on first broker reveal (two enabled displays) | already allocated | 2 |
| Fresh panel constructions for an idle global shortcut | already allocated | 1 selected display |
| Native pointer monitors after final hide | 2 | 0 |
| Maximum pending delivery ownership during a 20,000-position burst | 1 | 1 |
| Pending delivery ownership immediately after stop | 1 until queued drain ran | 0 |

The restart case deliberately leaves an old scheduled callback in the manual
scheduler, starts a fresh lifecycle lease, and queues a new pointer position.
The stale callback delivers nothing and cannot consume the successor position;
the fresh callback delivers exactly once. The final stop reports no pending or
buffered pointer delivery.
