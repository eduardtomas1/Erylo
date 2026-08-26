# Media capability slice

This slice defines the public media model in `EryloCore` and a lazy adapter/coordinator boundary in `EryloIntegrations`. It does not connect media state to `ActivityBroker` or UI lifecycle code.

## Reliability and energy contract

- Apple Music and Spotify use their public desktop Apple Event scripting dictionaries through the documented `/usr/bin/osascript` tool. There is no MediaRemote, private framework, OAuth, browser capture, network client, or shell evaluation.
- Enabling an adapter only changes local state and attaches an immediately finished update stream. It does not inspect an application, launch a process, prompt for Automation, or refresh media.
- A refresh or command is an explicit feature use. Before invoking AppleScript, the adapter checks the public `NSRunningApplication` surface and every fixed script independently refuses to launch a target that is not already running.
- Neither desktop scripting dictionary provides a reliable public state-change notification seam for this package. These adapters therefore expose explicit refresh only; they do not poll. A future event path must pass a reliability and idle-energy gate before replacing the finished stream.
- Each command is capability-checked when queued and again against the latest snapshot immediately before execution. Seek and volume accept finite numbers only and are clamped to the current duration and `0...1` respectively.
- Coordinator lifecycle and refresh work is generation-scoped. Disable invalidates old streams, refreshes, queued commands, snapshots, and health updates; command execution is serialized and bounded. Each desktop adapter independently bounds active-plus-queued work, so direct refresh floods cannot bypass the coordinator command bound.

The subprocess executor has a fixed executable path and closed script routes. Command data is independently revalidated as a bounded number and passed as an `argv` item; now-playing text never enters script source or command arguments. The runner bounds concurrent processes, drains stdout and stderr concurrently under hard byte caps, applies a one-shot timeout, and uses an exact-process TERM-to-KILL fallback. Cancellation is operation-ID-specific, including when two adapters share an injected executor; disabling one source cannot cancel another source's work.

## Permission behavior

The first explicit refresh or command against a running source can cause macOS to request Automation access. Missing applications, denied Automation, malformed output, command rejection, cancellation, and scripting failures map to typed `MediaError` values.

This repository is still a SwiftPM technical foundation rather than the signed application bundle. A packaged Hardened Runtime target must provide its reviewed Apple Events entitlement and user-facing usage description before shipping. This slice deliberately does not add or guess application signing metadata.

## Artwork and privacy

Snapshots contain either an opaque Apple Music source-asset reference or an HTTPS Spotify artwork reference plus a bounded cache key. The adapters do not resolve or download either reference.

Artwork loading and decoding are opt-in injected interfaces. Loaders receive a byte materialization limit and decoders receive pixel, dimension, and decoded-cost limits. The supplied actor pipeline is memory-only, coalesces same-key misses, caps distinct in-flight work, entry count, individual entries, and total decoded cost, evicts least-recent entries, and supports a generation-safe explicit purge. No disk cache or media history is retained.

Apple Music artwork bytes are not resolved in this slice because its desktop scripting surface does not expose a safe bounded reference-to-bytes route proven by this package. Spotify artwork URLs likewise remain inert until a future caller supplies an explicit, policy-reviewed loader.

## Verification boundary

`EryloMediaTests` is dependency-free and exercises capability gating, numeric validation/clamping, command and adapter admission bounds, latest-capability revalidation, lifecycle/refresh generations, exact-operation and shared-executor cancellation, stale snapshot rejection, semantic dedupe, source disappearance/recovery, inactive zero-work behavior, error mapping, subscriber limits/cleanup, text and identifier bounds, bounded/coalesced artwork plus purge races, fixed-script injection resistance, and subprocess capacity, pipe, timeout, escalation, and terminal-cause behavior.

The automated suite does not send Apple Events, display a real Automation prompt, fetch artwork, or assert behavior against particular installed Apple Music/Spotify versions. Those remain explicit manual compatibility checks for the signed app target.
