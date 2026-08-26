# File Hold core contract

`EryloFileHold` is a native macOS domain and storage slice. It deliberately does not install
application UI, own the panel lifecycle, or claim end-to-end Quick Look, share-sheet, AirDrop,
or cross-Space behavior.

## Ownership modes

- `temporaryCopy` publishes an atomically staged regular file under a dedicated app-owned root.
  Erylo records the copy's device, inode, size, and single-link invariant. It never deletes or
  modifies the source.
- `reference` stores a bounded security-scoped bookmark. Presentation starts the security scope,
  validates a local regular file with the original filesystem identity, refreshes live size/date
  metadata within configured capacity, and always releases successfully started access.

Every public ingest limit also has a non-configurable upper ceiling. Store-wide item and byte
accounting includes committed items, in-flight reservations, and unacknowledged recovery entries.
Input/provider prefixes, generated reports, path components, collision attempts, bookmark bytes,
and drag representation bytes are bounded.

## Root and deletion authority

The injected root's parent must already exist. The root leaf is claimed by atomic `mkdirat`; an
existing leaf is accepted only when it is owned by the effective user, mode `0700`, and contains
the exact Erylo marker. Descriptor identity, path identity, ownership, mode, and marker are
rechecked before storage operations.

Copy publication uses an exclusive atomic rename. Cleanup first atomically quarantines a name,
then verifies the expected regular-file identity and size before unlinking. Unknown substitutions
are restored. If restoration cannot safely complete, the store retains a privacy-safe
`FileHoldRecoveryRecord`; ordinary remove retries cannot erase that signal. A higher-level recovery
workflow must inspect/recover the relative entry and explicitly call `acknowledgeRecovery(for:)`.
Recovery capacity is exact only when a no-follow inspection verifies a regular, single-link file;
the record captures its byte count and filesystem identity rather than charging the former held
source size. Directories, links, special files, and unverifiable retained content are explicitly
`unquantifiable`. Erylo never traverses those entries and treats store byte capacity as full until
the recovery is explicitly acknowledged. Before the observer/race window, cleanup binds the
quarantined entry through an open no-follow descriptor. A record distinguishes a revalidated exact
relative name from a last-known app-generated relative name. If another actor moves the quarantine,
or reuses its name for a different entry, Erylo neither scans the root nor guesses a new locator; it
retains the last-known locator and unquantifiable accounting. Acknowledgement clears accounting but
never deletes the unknown, replacement, or relocated entry.

## Public drag representations

The decoder requests only `loadInPlaceFileRepresentation`. Every returned provider URL is read
through `NSFileCoordinator` with `.withoutChanges`, regardless of the `isInPlace` value. The
bounded `lstat`/`open`/`fstat`/read and URL decode happen synchronously on the coordinator-supplied
URL before its accessor returns. Coordination errors become `invalidDragRepresentation`.

In a signed sandbox, the decoder attempts security-scoped access for the provider URL and keeps
every successfully started scope alive across coordination and the complete bounded read, then
releases it before returning from the provider completion. A `false` start result is not by itself
an error because non-security-scoped provider URLs do not require a scope.

## Expiry and shutdown

Expiry uses one cancellable one-shot task per item and a store-global never-reused schedule nonce;
there is no idle polling. Updating, removing, or shutting down cancels stale work. A scheduler
failure never deletes a copy before its requested deadline: the item enters the available
`attentionRequired` state for manual save, expiry repair, or removal.

`shutdown()` disables new work, cancels and drains in-flight copy reservations, waits for active
temporary-copy presentation leases, performs identity-proven cleanup, and reports remaining
recovery entries. Integrators must await it when disabling File Hold or terminating gracefully.
Calling `shutdown()` from inside the same store's presentation callback throws
`reentrantShutdownFromPresentation`; the callback must unwind and its owner can then await shutdown.
This preserves lease draining without allowing a callback to wait on its own lease.

That reentrancy guard is a dynamic `TaskLocal` contract. Structured child work and ordinary tasks
that inherit task-local values remain guarded. `Task.detached` and legacy callback hops may not
inherit the presentation context; presentation code must not invoke shutdown through such a hop.
Instead, return from the presentation callback and let its owner initiate shutdown. A shutdown
started independently outside the callback intentionally waits until all presentation leases and
in-flight reservations drain; callers must not interpret that wait as a hang or skip the drain.

## Release blockers and UI limitations

- **Release blocker:** crash/power-loss recovery has no durable manifest yet. Graceful shutdown is
  covered, but persistent File Hold must not be enabled in a shipping app until startup recovery
  can enumerate and reconcile owned copies, stages, and quarantine records without guessing
  ownership.
- Quick Look thumbnail/preview and share/AirDrop are narrow URL-resource seams only. This package
  does not prove presentation UI, hardware discovery/transfer, focus behavior, or cross-Space
  behavior. Those require app-bundle integration and hardware/system testing outside this slice.
