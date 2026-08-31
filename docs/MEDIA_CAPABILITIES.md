# Media capability slice

This slice defines the public media model in `EryloCore` and a lazy adapter/coordinator boundary in `EryloIntegrations`. It does not connect media state to `ActivityBroker` or UI lifecycle code.

## Reliability and energy contract

- Apple Music and Spotify use their public desktop Apple Event scripting dictionaries through the documented `/usr/bin/osascript` tool. There is no MediaRemote, private framework, OAuth, browser capture, network client, or shell evaluation.
- Enabling an adapter only changes local state and attaches an immediately finished update stream. It does not inspect an application, launch a process, prompt for Automation, or refresh media.
- A refresh or command is an explicit feature use. Before invoking AppleScript, the adapter checks the public `NSRunningApplication` surface and every fixed script independently refuses to launch a target that is not already running.
- Neither desktop scripting dictionary provides a reliable public state-change notification seam for this package. These adapters therefore expose explicit refresh only; they do not poll. A future event path must pass a reliability and idle-energy gate before replacing the finished stream.
- Each command is capability-checked when queued and again against the latest snapshot immediately before execution. Seek and volume accept finite numbers only and are clamped to the current duration and `0...1` respectively.
- Coordinator lifecycle and refresh work is generation-scoped. Disable invalidates old streams, refreshes, queued commands, snapshots, and health updates; command execution is serialized and bounded. Each desktop adapter independently counts queued, active, and cancelled-but-unsettled physical work, so direct refresh floods and noncooperative injected seams cannot bypass admission bounds.

The subprocess executor has a fixed executable path and closed script routes. Command data is independently revalidated as a bounded number and passed as an `argv` item; now-playing text never enters script source or command arguments. Successful script output must be valid UTF-8 with exactly ten fields, including finite required duration, position, and volume numbers, before snapshot normalization or capability publication. Arbitrary-argv process types are Testing SPI and a compiler-level CI check keeps them unavailable to production clients. The runner bounds concurrent processes, owns spawn and the sole `waitpid` reap path, serializes signaling with reaping so the child PID cannot be reused first, escalates an unresponsive owned child to `SIGKILL`, drains stdout and stderr concurrently under hard byte caps, and bounds post-exit drain time when a descendant retains either pipe. Exact cancellation does not return until the child and readers settle. Cancellation is operation-specific, including when two adapters share an injected executor; disabling one source cannot cancel another source's work.

## Permission behavior

If this slice is deliberately mounted in a future build, the first explicit
refresh or command against a running source can cause macOS to request
Automation access. Missing applications, denied Automation, malformed output,
command rejection, cancellation, and scripting failures map to typed
`MediaError` values.

The current application does not mount either adapter. Its production bundle
therefore has no Apple Events usage description or automation entitlement, and
the release/repository policy rejects either declaration while media remains
unmounted. A future mount must update the reviewed production-capability
allowlist and restore accurate signing and usage-description metadata in the
same change; the dormant foundation alone is not authority to declare access.

## Artwork and privacy

Snapshots contain either an opaque Apple Music source-asset reference or an HTTPS Spotify artwork reference plus a bounded cache key. The adapters do not resolve or download either reference.

Artwork loading and decoding are opt-in injected interfaces. Loaders receive a byte materialization limit and decoders receive pixel, dimension, and decoded-cost limits. The supplied actor pipeline is memory-only, coalesces same-key misses, caps distinct physical work including cancelled-but-unsettled purge work, caps entry count, individual entries, and total decoded cost, evicts least-recent entries, and supports a generation-safe explicit purge. No disk cache or media history is retained.

Apple Music artwork bytes are not resolved in this slice because its desktop scripting surface does not expose a safe bounded reference-to-bytes route proven by this package. Spotify artwork URLs likewise remain inert until a future caller supplies an explicit, policy-reviewed loader.

## Verification boundary

`EryloMediaTests` is dependency-free and exercises capability gating, numeric validation/clamping, command and adapter admission bounds, latest-capability revalidation, lifecycle/refresh generations, exact-operation and shared-executor cancellation, stale snapshot rejection, semantic dedupe, source disappearance/recovery, inactive zero-work behavior, error mapping, subscriber limits/cleanup, text and identifier bounds, bounded/coalesced artwork plus purge races, fixed-script injection resistance, and subprocess capacity, pipe, timeout, escalation, and terminal-cause behavior.

The automated suite does not send Apple Events, display a real Automation
prompt, fetch artwork, or assert behavior against particular installed Apple
Music/Spotify versions. Those become explicit signed-app compatibility gates
only if media is mounted in a future production composition.
