import Darwin
import EryloFileHold
import Foundation

private func runHarness() async -> Never {
    var harness = FileHoldHarness()
    await harness.verifyCopyAndReferenceSemantics()
    await harness.verifyOrderingCollisionsAndDuplicates()
    await harness.verifyInputAndStoreBounds()
    await harness.verifyPartialFailureAndCancellation()
    await harness.verifyExpiryAndStaleTaskCancellation()
    await harness.verifyPresentationLeasesAndScopeRelease()
    await harness.verifyCleanupRetryAndSymlinkDefense()
    await harness.verifySourceGrowthAndCollisionAttemptBounds()
    await harness.verifyAdversarialCopyAndRecoveryBoundary()
    await harness.verifyExpiryLimitsShutdownAndHistory()
    await harness.verifyReferenceRevalidation()
    await harness.verifyPublicDragRepresentationCap()
    harness.finish()
}

await runHarness()

private struct FileHoldHarness {
    private var checkCount = 0
    private var failures: [String] = []
    private let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    mutating func verifyCopyAndReferenceSemantics() async {
        guard let sandbox = try? makeSandbox("semantics") else {
            recordFailure("copy/reference setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let source = sandbox.appendingPathComponent("original.txt")
            try Data("original".utf8).write(to: source)
            let copyRoot = sandbox.appendingPathComponent("copies", isDirectory: true)
            let copyStore = try makeStore(root: copyRoot, idPrefix: "copy")
            let copyItem = try requireHeld(
                await copyStore.ingest(
                    [source],
                    options: FileHoldIngestOptions(mode: .temporaryCopy)
                ),
                at: 0
            )

            check(copyItem.mode == .temporaryCopy, "temporary-copy mode is explicit")
            check(copyItem.source.originalURL == source, "copy retains original source metadata")
            check(copyItem.source.byteCount == 8, "copy records the inspected source size")
            check(copyItem.status == .available, "new copy is available")

            try Data("changed original".utf8).write(to: source, options: .atomic)
            let copiedData: Data = try await copyStore.withAccessibleURL(for: copyItem.id) {
                try Data(contentsOf: $0)
            }
            check(copiedData == Data("original".utf8), "temporary copy is independent of later source edits")

            check(await copyStore.remove(copyItem.id)?.outcome == .cleaned, "temporary copy cleanup succeeds")
            check(FileManager.default.fileExists(atPath: source.path), "copy cleanup never deletes the original")
            check(
                try Data(contentsOf: source) == Data("changed original".utf8),
                "copy cleanup never modifies the original"
            )
            check(
                await copyStore.remove(copyItem.id)?.outcome == .alreadyCleaned,
                "copy cleanup is idempotent"
            )

            let tracker = ReferenceTracker()
            let referenceRoot = sandbox.appendingPathComponent("references", isDirectory: true)
            let referenceStore = try makeStore(
                root: referenceRoot,
                codec: TestReferenceCodec(tracker: tracker),
                idPrefix: "reference"
            )
            let referenceItem = try requireHeld(
                await referenceStore.ingest(
                    [source],
                    options: FileHoldIngestOptions(mode: .reference)
                ),
                at: 0
            )
            check(referenceItem.mode == .reference, "reference mode is explicit")
            check(try directoryNames(referenceRoot).isEmpty, "reference mode creates no file copy")

            let referencedData: Data = try await referenceStore.withAccessibleURL(for: referenceItem.id) {
                try Data(contentsOf: $0)
            }
            check(referencedData == Data("changed original".utf8), "reference resolves the current original")
            check(tracker.successfulStarts == 1, "reference access starts once")
            check(tracker.stops == 1, "reference access stops after use")

            _ = await referenceStore.remove(referenceItem.id)
            check(FileManager.default.fileExists(atPath: source.path), "reference cleanup never deletes the original")
            check(
                try Data(contentsOf: source) == Data("changed original".utf8),
                "reference cleanup never modifies the original"
            )
        } catch {
            recordUnexpected(error, test: "copy/reference semantics")
        }
    }

    mutating func verifyOrderingCollisionsAndDuplicates() async {
        guard let sandbox = try? makeSandbox("ordering") else {
            recordFailure("ordering setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let firstDirectory = sandbox.appendingPathComponent("first", isDirectory: true)
            let secondDirectory = sandbox.appendingPathComponent("second", isDirectory: true)
            try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
            let first = firstDirectory.appendingPathComponent("same.txt")
            let second = secondDirectory.appendingPathComponent("same.txt")
            let third = sandbox.appendingPathComponent("third.txt")
            try Data("one".utf8).write(to: first)
            try Data("two".utf8).write(to: second)
            try Data("three".utf8).write(to: third)

            let root = sandbox.appendingPathComponent("root", isDirectory: true)
            let store = try makeStore(root: root, idPrefix: "order")
            let preexisting = root.appendingPathComponent("same.txt")
            try Data("sentinel".utf8).write(to: preexisting)
            let held = (await store.ingest(
                [first, second, third],
                options: FileHoldIngestOptions(mode: .temporaryCopy, duplicatePolicy: .allow)
            )).heldItems
            check(held.map(\.source.originalURL) == [first, second, third], "multi-file report preserves input order")
            check((await store.items()).map(\.id) == held.map(\.id), "store order is stable")
            check(relativeName(of: held[0]) == "same 2.txt", "preexisting collision uses a safe suffix")
            check(relativeName(of: held[1]) == "same 3.txt", "batch collision uses the next safe suffix")
            check(try Data(contentsOf: preexisting) == Data("sentinel".utf8), "collision handling never overwrites")

            let duplicateStore = try makeStore(
                root: sandbox.appendingPathComponent("duplicate-root", isDirectory: true),
                idPrefix: "duplicate"
            )
            let duplicateItems = (await duplicateStore.ingest(
                [first, first],
                options: FileHoldIngestOptions(mode: .reference, duplicatePolicy: .allow)
            )).heldItems
            check(duplicateItems.count == 2, "allow policy retains two explicit duplicate IDs")
            _ = await duplicateStore.remove(duplicateItems[0].id)
            let rejected = await duplicateStore.ingest(
                [first],
                options: FileHoldIngestOptions(mode: .reference, duplicatePolicy: .reject)
            )
            check(
                failure(of: rejected, at: 0) == .duplicate(existingItemID: duplicateItems[1].id),
                "removing one allowed duplicate leaves the other visible to reject policy"
            )
            _ = await duplicateStore.remove(duplicateItems[1].id)
            let accepted = await duplicateStore.ingest(
                [first],
                options: FileHoldIngestOptions(mode: .reference, duplicatePolicy: .reject)
            )
            check(accepted.heldItems.count == 1, "duplicate identity is released after every owner is cleaned")

            let hardLink = sandbox.appendingPathComponent("hard-link.txt")
            try FileManager.default.linkItem(at: first, to: hardLink)
            let hardLinkReport = await duplicateStore.ingest(
                [hardLink],
                options: FileHoldIngestOptions(mode: .reference, duplicatePolicy: .reject)
            )
            check(failure(of: hardLinkReport, at: 0) != nil, "duplicate detection uses filesystem identity")
        } catch {
            recordUnexpected(error, test: "ordering/collisions/duplicates")
        }
    }

    mutating func verifyInputAndStoreBounds() async {
        guard let sandbox = try? makeSandbox("bounds") else {
            recordFailure("bounds setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let valid = sandbox.appendingPathComponent("valid.bin")
            let second = sandbox.appendingPathComponent("second.bin")
            let tiny = sandbox.appendingPathComponent("tiny.bin")
            try Data(repeating: 1, count: 4).write(to: valid)
            try Data(repeating: 2, count: 4).write(to: second)
            try Data(repeating: 3, count: 2).write(to: tiny)
            let directory = sandbox.appendingPathComponent("directory", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let symlink = sandbox.appendingPathComponent("source-link")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid)

            let validationStore = try makeStore(
                root: sandbox.appendingPathComponent("validation-root", isDirectory: true),
                idPrefix: "validation"
            )
            let validation = await validationStore.ingest(
                [
                    URL(string: "https://example.com/file")!,
                    URL(string: "file://example.com/tmp/remote")!,
                    sandbox.appendingPathComponent("missing"),
                    directory,
                    symlink,
                    valid,
                ],
                options: FileHoldIngestOptions(mode: .temporaryCopy)
            )
            check(failure(of: validation, at: 0) == .notFileURL, "non-file URL is rejected")
            check(failure(of: validation, at: 1) == .nonLocalFileURL, "non-local file URL is rejected")
            check(failure(of: validation, at: 2) == .sourceMissing, "missing source is rejected")
            check(failure(of: validation, at: 3) == .sourceIsNotRegularFile, "directory source is rejected")
            check(failure(of: validation, at: 4) == .sourceIsSymbolicLink, "source symlink is rejected")
            check(validation.heldItems.count == 1, "valid input survives neighboring validation failures")

            let pathStore = try makeStore(
                root: sandbox.appendingPathComponent("path-root", isDirectory: true),
                limits: FileHoldIngestLimits(maximumPathBytes: 4),
                idPrefix: "path"
            )
            check(
                failure(of: await pathStore.ingest([valid], options: .init(mode: .temporaryCopy)), at: 0)
                    == .pathTooLong(maximumBytes: 4),
                "path byte bound is enforced"
            )

            let itemSizeStore = try makeStore(
                root: sandbox.appendingPathComponent("item-size-root", isDirectory: true),
                limits: FileHoldIngestLimits(maximumItemBytes: 3),
                idPrefix: "item-size"
            )
            check(
                failure(of: await itemSizeStore.ingest([valid], options: .init(mode: .temporaryCopy)), at: 0)
                    == .itemTooLarge(maximumBytes: 3, actualBytes: 4),
                "per-item byte bound is enforced"
            )

            let inputCapStore = try makeStore(
                root: sandbox.appendingPathComponent("input-root", isDirectory: true),
                limits: FileHoldIngestLimits(maximumInputCount: 2, maximumItemCount: 10),
                idPrefix: "input"
            )
            let inputCap = await inputCapStore.ingest(
                [valid, second, tiny, valid, second],
                options: .init(mode: .reference, duplicatePolicy: .allow)
            )
            check(inputCap.entries.count == 3, "input cap reports its prefix and first rejected position")
            check(failure(of: inputCap, at: 2) == .tooManyInputs(maximum: 2), "input count bound short-circuits excess inputs")
            check(inputCap.unprocessedInputCount == 2, "input bound caps failure-report allocation")

            let tracker = ReferenceTracker(bookmarkFailureNames: ["valid.bin"])
            let capacityStore = try makeStore(
                root: sandbox.appendingPathComponent("capacity-root", isDirectory: true),
                limits: FileHoldIngestLimits(
                    maximumInputCount: 10,
                    maximumItemCount: 2,
                    maximumItemBytes: 10,
                    maximumTotalBytes: 5
                ),
                codec: TestReferenceCodec(tracker: tracker),
                idPrefix: "capacity"
            )
            let afterFailure = await capacityStore.ingest(
                [valid, second],
                options: .init(mode: .reference)
            )
            check(failure(of: afterFailure, at: 0) == .bookmarkCreationFailed, "bookmark failure is reported in place")
            check(afterFailure.heldItems.map(\.source.originalURL) == [second], "failed hold releases its byte reservation")
            check(
                failure(of: await capacityStore.ingest([tiny], options: .init(mode: .reference)), at: 0)
                    == .totalSizeExceeded(maximumBytes: 5),
                "total byte cap spans repeated ingest calls"
            )
            _ = await capacityStore.remove(try requireHeld(afterFailure, at: 1).id)
            check(
                (await capacityStore.ingest([tiny], options: .init(mode: .reference))).heldItems.count == 1,
                "successful cleanup releases store byte capacity"
            )

            let countStore = try makeStore(
                root: sandbox.appendingPathComponent("count-root", isDirectory: true),
                limits: FileHoldIngestLimits(maximumItemCount: 1),
                idPrefix: "count"
            )
            check(
                (await countStore.ingest([valid], options: .init(mode: .reference))).heldItems.count == 1,
                "first store-count slot is accepted"
            )
            check(
                failure(of: await countStore.ingest([second], options: .init(mode: .reference)), at: 0)
                    == .tooManyItems(maximum: 1),
                "item count cap spans repeated ingest calls"
            )
        } catch {
            recordUnexpected(error, test: "input/store bounds")
        }
    }

    mutating func verifyPartialFailureAndCancellation() async {
        guard let sandbox = try? makeSandbox("partial-cancel") else {
            recordFailure("partial/cancel setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let first = sandbox.appendingPathComponent("first")
            let missing = sandbox.appendingPathComponent("missing")
            let third = sandbox.appendingPathComponent("third")
            try Data("first".utf8).write(to: first)
            try Data("third".utf8).write(to: third)
            let partialStore = try makeStore(
                root: sandbox.appendingPathComponent("partial-root", isDirectory: true),
                idPrefix: "partial"
            )
            let partial = await partialStore.ingest(
                [first, missing, third],
                options: .init(mode: .temporaryCopy)
            )
            check(partial.entries.map(\.inputIndex) == [0, 1, 2], "partial report keeps stable input indices")
            check(partial.heldItems.map(\.source.originalURL) == [first, third], "partial success keeps stable order")
            check(failure(of: partial, at: 1) == .sourceMissing, "partial report isolates failing input")

            let cancelledStore = try makeStore(
                root: sandbox.appendingPathComponent("pre-cancel-root", isDirectory: true),
                idPrefix: "pre-cancel"
            )
            let preCancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await cancelledStore.ingest([first, third], options: .init(mode: .temporaryCopy))
            }
            let preCancelledReport = await preCancelled.value
            check(
                preCancelledReport.entries.allSatisfy { $0.outcome == .failed(.cancelled) },
                "pre-cancelled ingest reports every unstarted item"
            )
            check((await cancelledStore.items()).isEmpty, "pre-cancelled ingest stores nothing")

            let large = sandbox.appendingPathComponent("large.bin")
            try createSparseFile(at: large, byteCount: 64 * 1_024 * 1_024)
            let midCancelRoot = sandbox.appendingPathComponent("mid-cancel-root", isDirectory: true)
            let midCancelStore = try makeStore(root: midCancelRoot, idPrefix: "mid-cancel")
            let midCancelTask = Task {
                await midCancelStore.ingest([large], options: .init(mode: .temporaryCopy))
            }
            check(await waitForStage(in: midCancelRoot), "cancellation test observes staged copy")
            midCancelTask.cancel()
            check(failure(of: await midCancelTask.value, at: 0) == .cancelled, "mid-copy cancellation is reported")
            check(try directoryNames(midCancelRoot).isEmpty, "mid-copy cancellation removes staging data")
            check(try fileSize(large) == 64 * 1_024 * 1_024, "mid-copy cancellation leaves original intact")
        } catch {
            recordUnexpected(error, test: "partial failure/cancellation")
        }
    }

    mutating func verifyExpiryAndStaleTaskCancellation() async {
        guard let sandbox = try? makeSandbox("expiry") else {
            recordFailure("expiry setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let source = sandbox.appendingPathComponent("expiring.txt")
            try Data("keep original".utf8).write(to: source)
            let scheduler = ManualExpiryScheduler()
            let store = try makeStore(
                root: sandbox.appendingPathComponent("root", isDirectory: true),
                scheduler: scheduler,
                idPrefix: "expiry"
            )
            let firstDeadline = fixedNow.addingTimeInterval(10)
            let item = try requireHeld(
                await store.ingest([source], options: .init(mode: .temporaryCopy, expiresAt: firstDeadline)),
                at: 0
            )
            let copyURL: URL = try await store.withAccessibleURL(for: item.id) { $0 }
            check(await waitForPending(scheduler, count: 1), "expiry schedules one one-shot task")

            let secondDeadline = fixedNow.addingTimeInterval(20)
            _ = try await store.updateExpiry(for: item.id, expiresAt: secondDeadline)
            check(await waitForCancellation(scheduler, count: 1), "updating expiry cancels stale work")
            await scheduler.advance(to: firstDeadline)
            await yieldSeveralTimes()
            check(await store.item(id: item.id)?.status == .available, "stale expiry cannot remove updated item")
            check(FileManager.default.fileExists(atPath: copyURL.path), "stale expiry leaves held copy present")

            await scheduler.advance(to: secondDeadline)
            check(
                await waitForStatus(store, itemID: item.id, expected: .expired(at: secondDeadline)),
                "current expiry transitions deterministically"
            )
            check(!FileManager.default.fileExists(atPath: copyURL.path), "expiry cleans app-owned copy")
            check(try Data(contentsOf: source) == Data("keep original".utf8), "expiry preserves original bytes")

            let removalScheduler = ManualExpiryScheduler()
            let removalStore = try makeStore(
                root: sandbox.appendingPathComponent("removal-root", isDirectory: true),
                scheduler: removalScheduler,
                idPrefix: "removal"
            )
            let deadline = fixedNow.addingTimeInterval(30)
            let removalItem = try requireHeld(
                await removalStore.ingest([source], options: .init(mode: .temporaryCopy, expiresAt: deadline)),
                at: 0
            )
            check(await waitForPending(removalScheduler, count: 1), "removal case schedules expiry once")
            _ = await removalStore.remove(removalItem.id)
            check(await waitForCancellation(removalScheduler, count: 1), "removing item cancels expiry work")
            await removalScheduler.advance(to: deadline)
            await yieldSeveralTimes()
            check(
                await removalStore.item(id: removalItem.id)?.status == .removed(at: fixedNow),
                "cancelled stale expiry cannot overwrite removed status"
            )
        } catch {
            recordUnexpected(error, test: "expiry/stale cancellation")
        }
    }

    mutating func verifyPresentationLeasesAndScopeRelease() async {
        guard let sandbox = try? makeSandbox("leases") else {
            recordFailure("lease setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let source = sandbox.appendingPathComponent("leased.txt")
            try Data("lease".utf8).write(to: source)
            let store = try makeStore(
                root: sandbox.appendingPathComponent("copy-root", isDirectory: true),
                idPrefix: "lease"
            )
            let item = try requireHeld(
                await store.ingest([source], options: .init(mode: .temporaryCopy)),
                at: 0
            )
            let gate = LeaseGate()
            let leaseTask = Task {
                try await store.withAccessibleURL(for: item.id) { url in
                    await gate.enter(url: url)
                    return FileManager.default.fileExists(atPath: url.path)
                }
            }
            let leasedURL = await gate.waitUntilEntered()
            let deferred = await store.remove(item.id)
            check(deferred?.outcome == .deferredUntilLeaseEnds, "remove defers cleanup during active lease")
            check(
                deferred?.item.status == .cleanupPending(.removed(at: fixedNow)),
                "deferred removal has explicit pending status"
            )
            check(FileManager.default.fileExists(atPath: leasedURL.path), "leased copy survives actor re-entry")
            await gate.release()
            check(try await leaseTask.value, "lease retains access until operation returns")
            check(
                await waitForStatus(store, itemID: item.id, expected: .removed(at: fixedNow)),
                "deferred cleanup completes after final lease"
            )
            check(!FileManager.default.fileExists(atPath: leasedURL.path), "copy unlinks after lease release")

            let first = sandbox.appendingPathComponent("first-reference")
            let second = sandbox.appendingPathComponent("second-reference")
            let denied = sandbox.appendingPathComponent("denied-reference")
            try Data("one".utf8).write(to: first)
            try Data("two".utf8).write(to: second)
            try Data("deny".utf8).write(to: denied)
            let tracker = ReferenceTracker(deniedAccessNames: ["denied-reference"])
            let referenceStore = try makeStore(
                root: sandbox.appendingPathComponent("reference-root", isDirectory: true),
                codec: TestReferenceCodec(tracker: tracker),
                idPrefix: "scope"
            )
            let references = (await referenceStore.ingest(
                [first, second, denied],
                options: .init(mode: .reference)
            )).heldItems
            do {
                let _: Void = try await referenceStore.withPresentationResources(
                    itemIDs: Array(references.prefix(2).map(\.id)),
                    purpose: .share
                ) { resources in
                    guard resources.map(\.url) == [first, second] else {
                        throw ProbeError.unexpectedResources
                    }
                    throw ProbeError.expected
                }
                recordFailure("reference scope test expected caller error")
            } catch ProbeError.expected {
                check(tracker.successfulStarts == 2, "multi-reference presentation starts each scope")
                check(tracker.stops == 2, "caller error releases every started scope")
            }

            do {
                let _: Void = try await referenceStore.withPresentationResources(
                    itemIDs: [references[0].id, references[2].id],
                    purpose: .quickLookPreview
                ) { _ in () }
                recordFailure("denied reference scope unexpectedly succeeded")
            } catch FileHoldError.securityScopeDenied {
                check(tracker.successfulStarts == 3, "partial setup starts first valid reference")
                check(tracker.stops == 3, "partial setup failure releases earlier scope")
                check(tracker.activeAccesses == 0, "no security scope leaks after failure")
            }

            let reentrantRoot = sandbox.appendingPathComponent("reentrant-shutdown-root")
            let reentrantStore = try makeStore(root: reentrantRoot, idPrefix: "reentrant-shutdown")
            let reentrantItem = try requireHeld(
                await reentrantStore.ingest([source], options: .init(mode: .temporaryCopy)),
                at: 0
            )
            let rejectedBeforeDeadline = await valueBeforeHardDeadline {
                do {
                    return try await reentrantStore.withAccessibleURL(for: reentrantItem.id) { _ in
                        do {
                            _ = try await reentrantStore.shutdown()
                            return false
                        } catch FileHoldError.reentrantShutdownFromPresentation {
                            return true
                        } catch {
                            return false
                        }
                    }
                } catch {
                    return false
                }
            }
            check(
                rejectedBeforeDeadline,
                "same-store shutdown from presentation fails typed before hard deadline"
            )
            check(
                await reentrantStore.item(id: reentrantItem.id)?.status == .available,
                "reentrant shutdown rejection leaves the lease/item usable"
            )
            let shutdownReport = try await reentrantStore.shutdown()
            check(
                shutdownReport.cleanupResults.first?.outcome == .cleaned,
                "shutdown drains normally after presentation callback unwinds"
            )
        } catch {
            recordUnexpected(error, test: "presentation leases/scope release")
        }
    }

    mutating func verifyCleanupRetryAndSymlinkDefense() async {
        guard let sandbox = try? makeSandbox("cleanup-defense") else {
            recordFailure("cleanup defense setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let source = sandbox.appendingPathComponent("original.txt")
            let outside = sandbox.appendingPathComponent("outside.txt")
            try Data("original".utf8).write(to: source)
            try Data("outside".utf8).write(to: outside)

            let sourceLink = sandbox.appendingPathComponent("source-link")
            try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
            let sourceLinkStore = try makeStore(
                root: sandbox.appendingPathComponent("source-link-root", isDirectory: true),
                idPrefix: "source-link"
            )
            check(
                failure(of: await sourceLinkStore.ingest([sourceLink], options: .init(mode: .temporaryCopy)), at: 0)
                    == .sourceIsSymbolicLink,
                "symlink source cannot redirect traversal"
            )

            let realRoot = sandbox.appendingPathComponent("real-root", isDirectory: true)
            try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
            let linkedRoot = sandbox.appendingPathComponent("linked-root")
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
            do {
                _ = try makeStore(root: linkedRoot, idPrefix: "bad-root")
                recordFailure("symlink storage root was accepted")
            } catch FileHoldError.unsafeStorage {
                check(true, "symlink storage root is rejected")
            }

            let leafRoot = sandbox.appendingPathComponent("leaf-root", isDirectory: true)
            let leafStore = try makeStore(root: leafRoot, idPrefix: "leaf")
            let leafItem = try requireHeld(
                await leafStore.ingest([source], options: .init(mode: .temporaryCopy)),
                at: 0
            )
            let copyURL: URL = try await leafStore.withAccessibleURL(for: leafItem.id) { $0 }
            try FileManager.default.removeItem(at: copyURL)
            try FileManager.default.createSymbolicLink(at: copyURL, withDestinationURL: outside)
            do {
                let _: URL = try await leafStore.withAccessibleURL(for: leafItem.id) { $0 }
                recordFailure("symlink-substituted held copy was presented")
            } catch FileHoldError.unsafeStorage {
                check(true, "presentation rejects symlink-substituted copy")
            }
            check(
                await leafStore.remove(leafItem.id)?.outcome == .failed(.unsafeStorage),
                "cleanup preserves a substituted leaf it cannot prove it owns"
            )
            check(FileManager.default.fileExists(atPath: copyURL.path), "substituted symlink remains for explicit recovery")
            check(try Data(contentsOf: outside) == Data("outside".utf8), "leaf cleanup never follows symlink target")

            let retryRoot = sandbox.appendingPathComponent("retry-root", isDirectory: true)
            let retryStore = try makeStore(root: retryRoot, idPrefix: "retry")
            let rootPermissions = try FileManager.default.attributesOfItem(atPath: retryRoot.path)[.posixPermissions] as? NSNumber
            check(
                rootPermissions?.intValue == 0o700,
                "opened app-owned root is restricted through its verified descriptor"
            )
            let retryItem = try requireHeld(
                await retryStore.ingest([source], options: .init(mode: .temporaryCopy)),
                at: 0
            )
            let movedRoot = sandbox.appendingPathComponent("retry-root-moved", isDirectory: true)
            let attackerRoot = sandbox.appendingPathComponent("attacker-root", isDirectory: true)
            try FileManager.default.createDirectory(at: attackerRoot, withIntermediateDirectories: true)
            let attackerFile = attackerRoot.appendingPathComponent(relativeName(of: retryItem))
            try Data("attacker".utf8).write(to: attackerFile)
            try FileManager.default.moveItem(at: retryRoot, to: movedRoot)
            try FileManager.default.createSymbolicLink(at: retryRoot, withDestinationURL: attackerRoot)

            let failedCleanup = await retryStore.remove(retryItem.id)
            check(failedCleanup?.outcome == .failed(.unsafeStorage), "root replacement fails closed")
            if case .cleanupFailed(error: .unsafeStorage, disposition: .removed(at: fixedNow), at: fixedNow)?
                = failedCleanup?.item.status {
                check(true, "failed cleanup retains retryable disposition")
            } else {
                recordFailure("failed cleanup did not retain retryable status")
            }
            check(try Data(contentsOf: attackerFile) == Data("attacker".utf8), "root replacement cannot escape boundary")

            try FileManager.default.removeItem(at: retryRoot)
            try FileManager.default.moveItem(at: movedRoot, to: retryRoot)
            check(await retryStore.remove(retryItem.id)?.outcome == .cleaned, "failed physical cleanup can be retried")
            check(
                await retryStore.remove(retryItem.id)?.outcome == .alreadyCleaned,
                "already-cleaned follows physical cleanup success only"
            )
            check(try Data(contentsOf: source) == Data("original".utf8), "cleanup defenses preserve original bytes")
        } catch {
            recordUnexpected(error, test: "cleanup retry/symlink defense")
        }
    }

    mutating func verifySourceGrowthAndCollisionAttemptBounds() async {
        guard let sandbox = try? makeSandbox("copy-bounds") else {
            recordFailure("copy bound setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let growingSource = sandbox.appendingPathComponent("growing.bin")
            try createSparseFile(at: growingSource, byteCount: 64 * 1_024 * 1_024)
            let growthRoot = sandbox.appendingPathComponent("growth-root", isDirectory: true)
            let growthStore = try makeStore(
                root: growthRoot,
                limits: FileHoldIngestLimits(
                    maximumItemBytes: 64 * 1_024 * 1_024,
                    maximumTotalBytes: 64 * 1_024 * 1_024
                ),
                idPrefix: "growth"
            )
            let growthTask = Task {
                await growthStore.ingest([growingSource], options: .init(mode: .temporaryCopy))
            }
            check(await waitForStage(in: growthRoot), "growth test observes staged copy")
            let writer = try FileHandle(forWritingTo: growingSource)
            try writer.seekToEnd()
            try writer.write(contentsOf: Data([0xff]))
            try writer.close()
            check(
                failure(of: await growthTask.value, at: 0) == .sourceChangedDuringCopy,
                "source growth cannot bypass copied-byte limits"
            )
            check(try directoryNames(growthRoot).isEmpty, "growth failure cleans staging data")

            let source = sandbox.appendingPathComponent("same.txt")
            try Data("copy".utf8).write(to: source)
            let collisionRoot = sandbox.appendingPathComponent("collision-root", isDirectory: true)
            let collisionStore = try makeStore(root: collisionRoot, idPrefix: "collision-limit")
            for index in 1...1_024 {
                let name = index == 1 ? "same.txt" : "same \(index).txt"
                try Data().write(to: collisionRoot.appendingPathComponent(name))
            }
            check(
                failure(
                    of: await collisionStore.ingest([source], options: .init(mode: .temporaryCopy)),
                    at: 0
                ) == .copyFailed,
                "collision search has finite attempt bound"
            )
            check(
                try directoryNames(collisionRoot).filter { $0.hasPrefix(".erylo-stage-") }.isEmpty,
                "collision exhaustion removes stage"
            )

            let longExtensionName = "x." + String(repeating: "e", count: 230)
            let longExtensionSource = sandbox.appendingPathComponent(longExtensionName)
            try Data("long-extension".utf8).write(to: longExtensionSource)
            let longNameRoot = sandbox.appendingPathComponent("long-name-root", isDirectory: true)
            let longNameStore = try makeStore(root: longNameRoot, idPrefix: "long-name")
            let longNameItem = try requireHeld(
                await longNameStore.ingest(
                    [longExtensionSource],
                    options: .init(mode: .temporaryCopy)
                ),
                at: 0
            )
            check(
                relativeName(of: longNameItem).utf8.count <= 200,
                "destination component bound includes an oversized extension"
            )

            let occupiedStageRoot = sandbox.appendingPathComponent("occupied-stage-root", isDirectory: true)
            let stageStore = try makeStore(root: occupiedStageRoot, idPrefix: "stage")
            let occupiedStage = occupiedStageRoot.appendingPathComponent(".erylo-stage-stage-1-1")
            try Data("sentinel".utf8).write(to: occupiedStage)
            check(
                (await stageStore.ingest([source], options: .init(mode: .temporaryCopy))).heldItems.count == 1,
                "atomic stage creation retries a bounded EEXIST collision"
            )
            check(
                try Data(contentsOf: occupiedStage) == Data("sentinel".utf8),
                "stage retry never overwrites an existing entry"
            )

            let reservationSource = sandbox.appendingPathComponent("reservation.bin")
            try createSparseFile(at: reservationSource, byteCount: 32 * 1_024 * 1_024)
            let reservationRoot = sandbox.appendingPathComponent("reservation-root", isDirectory: true)
            let reservationStore = try makeStore(
                root: reservationRoot,
                limits: FileHoldIngestLimits(maximumItemCount: 1),
                idPrefix: "reservation"
            )
            let firstTask = Task {
                await reservationStore.ingest([reservationSource], options: .init(mode: .temporaryCopy))
            }
            check(await waitForStage(in: reservationRoot), "reservation test observes in-flight copy")
            check(
                failure(
                    of: await reservationStore.ingest([source], options: .init(mode: .temporaryCopy)),
                    at: 0
                ) == .tooManyItems(maximum: 1),
                "in-flight reservation enforces cap across actor re-entry"
            )
            _ = await firstTask.value

            let pendingIDSource = sandbox.appendingPathComponent("pending-id.bin")
            try createSparseFile(at: pendingIDSource, byteCount: 32 * 1_024 * 1_024)
            let pendingIDRoot = sandbox.appendingPathComponent("pending-id-root", isDirectory: true)
            let constantIDs = ConstantIDGenerator("fixed-id")
            let pendingNow = fixedNow
            let pendingIDStore = try FileHoldStore(
                rootURL: pendingIDRoot,
                limits: FileHoldIngestLimits(maximumItemCount: 2),
                referenceCodec: TestReferenceCodec(tracker: ReferenceTracker()),
                now: { pendingNow },
                makeID: { constantIDs.next() }
            )
            let pendingIDTask = Task {
                await pendingIDStore.ingest(
                    [pendingIDSource],
                    options: .init(mode: .temporaryCopy, duplicatePolicy: .allow)
                )
            }
            check(await waitForStage(in: pendingIDRoot), "pending-ID test observes reserved in-flight item")
            let pendingIDCollision = await pendingIDStore.ingest(
                [source],
                options: .init(mode: .temporaryCopy, duplicatePolicy: .allow)
            )
            check(
                failure(of: pendingIDCollision, at: 0) == .identifierAllocationFailed,
                "pending IDs participate in uniqueness checks"
            )
            check(constantIDs.callCount == 1_025, "ID allocation attempts have a hard bound")
            let completedPendingID = await pendingIDTask.value
            check(completedPendingID.heldItems.map(\.id) == [HeldFileID(rawValue: "fixed-id")], "reserved ID commits once without overwrite")
            check((await pendingIDStore.items()).count == 1, "pending-ID collision preserves ordering and accounting")
        } catch {
            recordUnexpected(error, test: "source growth/collision attempts")
        }
    }

    mutating func verifyAdversarialCopyAndRecoveryBoundary() async {
        guard let sandbox = try? makeSandbox("adversarial-copy") else {
            recordFailure("adversarial copy setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let source = sandbox.appendingPathComponent("source.bin")
            try Data(repeating: 0x31, count: 512 * 1_024).write(to: source)

            let rewriteObserver = GatedCopyObserver()
            let rewriteRoot = sandbox.appendingPathComponent("rewrite-root")
            let rewriteStore = try makeStore(
                root: rewriteRoot,
                copyObserver: rewriteObserver,
                idPrefix: "rewrite"
            )
            let rewriteTask = Task {
                await rewriteStore.ingest([source], options: .init(mode: .temporaryCopy))
            }
            await rewriteObserver.waitUntilReached()
            let rewriteHandle = try FileHandle(forWritingTo: source)
            try rewriteHandle.seek(toOffset: 0)
            try rewriteHandle.write(contentsOf: Data(repeating: 0x32, count: 512 * 1_024))
            try rewriteHandle.synchronize()
            try rewriteHandle.close()
            await rewriteObserver.release()
            check(
                failure(of: await rewriteTask.value, at: 0) == .sourceChangedDuringCopy,
                "same-size in-place source rewrite is detected by timestamps"
            )
            check(try directoryNames(rewriteRoot).isEmpty, "rewrite failure removes only its owned stage")

            let stageObserver = GatedCopyObserver()
            let stageRoot = sandbox.appendingPathComponent("stage-replacement-root")
            let stageStore = try makeStore(
                root: stageRoot,
                copyObserver: stageObserver,
                idPrefix: "stage-replacement"
            )
            let stageTask = Task {
                await stageStore.ingest([source], options: .init(mode: .temporaryCopy))
            }
            await stageObserver.waitUntilReached()
            guard let stageName = try directoryNames(stageRoot).first(where: {
                $0.hasPrefix(".erylo-stage-")
            }) else {
                throw FileHoldError.copyFailed
            }
            let displacedStage = stageRoot.appendingPathComponent("displaced-owned-stage")
            try FileManager.default.moveItem(
                at: stageRoot.appendingPathComponent(stageName),
                to: displacedStage
            )
            try Data("stage replacement".utf8).write(
                to: stageRoot.appendingPathComponent(stageName)
            )
            await stageObserver.release()
            check(
                failure(of: await stageTask.value, at: 0) == .unsafeStorage,
                "stage replacement fails without unlinking the replacement"
            )
            check(
                try directoryNames(stageRoot).contains { name in
                    (try? Data(contentsOf: stageRoot.appendingPathComponent(name)))
                        == Data("stage replacement".utf8)
                },
                "stage replacement bytes survive identity-safe failure cleanup"
            )

            let publishObserver = PublishGateObserver()
            let publishRoot = sandbox.appendingPathComponent("publish-replacement-root")
            let publishStore = try makeStore(
                root: publishRoot,
                copyObserver: publishObserver,
                idPrefix: "publish-replacement"
            )
            let publishTask = Task {
                await publishStore.ingest([source], options: .init(mode: .temporaryCopy))
            }
            let publishedName = await publishObserver.waitUntilPublished()
            let publishedURL = publishRoot.appendingPathComponent(publishedName)
            try FileManager.default.moveItem(
                at: publishedURL,
                to: publishRoot.appendingPathComponent("displaced-owned-destination")
            )
            try Data("destination replacement".utf8).write(to: publishedURL)
            await publishObserver.release()
            check(
                failure(of: await publishTask.value, at: 0) == .unsafeStorage,
                "post-publication replacement fails identity-safe"
            )
            check(
                try Data(contentsOf: publishedURL) == Data("destination replacement".utf8),
                "post-publication replacement is restored, not deleted"
            )

            let cancellationObserver = PublishGateObserver()
            let cancellationRoot = sandbox.appendingPathComponent("publish-cancel-root")
            let cancellationStore = try makeStore(
                root: cancellationRoot,
                copyObserver: cancellationObserver,
                idPrefix: "publish-cancel"
            )
            let cancellationTask = Task {
                await cancellationStore.ingest([source], options: .init(mode: .temporaryCopy))
            }
            _ = await cancellationObserver.waitUntilPublished()
            cancellationTask.cancel()
            await cancellationObserver.release()
            check(
                failure(of: await cancellationTask.value, at: 0) == .cancelled,
                "cancellation at the publication await cannot commit"
            )
            check(try directoryNames(cancellationRoot).isEmpty, "publish cancellation cleans the exact owned inode")

            let replacementRoot = sandbox.appendingPathComponent("regular-replacement-root")
            let replacementStore = try makeStore(root: replacementRoot, idPrefix: "regular-replacement")
            let replacementItem = try requireHeld(
                await replacementStore.ingest([source], options: .init(mode: .temporaryCopy)),
                at: 0
            )
            let replacementURL = replacementRoot.appendingPathComponent(relativeName(of: replacementItem))
            try FileManager.default.moveItem(
                at: replacementURL,
                to: replacementRoot.appendingPathComponent("moved-owned-copy")
            )
            try Data("unrelated regular".utf8).write(to: replacementURL)
            check(
                await replacementStore.remove(replacementItem.id)?.outcome == .failed(.unsafeStorage),
                "regular-file substitution is not deleted"
            )
            check(try Data(contentsOf: replacementURL) == Data("unrelated regular".utf8), "regular substitution remains intact")

            let hardlinkRoot = sandbox.appendingPathComponent("hardlink-replacement-root")
            let hardlinkStore = try makeStore(root: hardlinkRoot, idPrefix: "hardlink-replacement")
            let hardlinkItem = try requireHeld(
                await hardlinkStore.ingest([source], options: .init(mode: .temporaryCopy)),
                at: 0
            )
            let hardlinkURL = hardlinkRoot.appendingPathComponent(relativeName(of: hardlinkItem))
            try FileManager.default.moveItem(
                at: hardlinkURL,
                to: hardlinkRoot.appendingPathComponent("moved-hardlink-owned")
            )
            let unrelated = sandbox.appendingPathComponent("unrelated-hardlink-source")
            try Data("unrelated hardlink".utf8).write(to: unrelated)
            try FileManager.default.linkItem(at: unrelated, to: hardlinkURL)
            check(
                await hardlinkStore.remove(hardlinkItem.id)?.outcome == .failed(.unsafeStorage),
                "hardlink substitution is not deleted"
            )
            check(try Data(contentsOf: unrelated) == Data("unrelated hardlink".utf8), "hardlink source remains intact")

            let missingRoot = sandbox.appendingPathComponent("missing-copy-root")
            let missingStore = try makeStore(root: missingRoot, idPrefix: "missing-copy")
            let missingItem = try requireHeld(
                await missingStore.ingest([source], options: .init(mode: .temporaryCopy)),
                at: 0
            )
            try FileManager.default.removeItem(
                at: missingRoot.appendingPathComponent(relativeName(of: missingItem))
            )
            check(
                await missingStore.remove(missingItem.id)?.outcome == .cleaned,
                "externally absent copy finalizes without touching a future replacement"
            )

            let recoveryRoot = sandbox.appendingPathComponent("recovery-root")
            let recoveryObserver = QuarantineCollisionObserver(root: recoveryRoot)
            let recoveryStore = try makeStore(
                root: recoveryRoot,
                limits: FileHoldIngestLimits(
                    maximumItemCount: 2,
                    maximumItemBytes: 512 * 1_024,
                    maximumTotalBytes: 512 * 1_024
                ),
                storageObserver: recoveryObserver,
                idPrefix: "recovery"
            )
            let recoveryItem = try requireHeld(
                await recoveryStore.ingest([source], options: .init(mode: .temporaryCopy)),
                at: 0
            )
            let recoveryURL = recoveryRoot.appendingPathComponent(relativeName(of: recoveryItem))
            try FileManager.default.moveItem(
                at: recoveryURL,
                to: recoveryRoot.appendingPathComponent("displaced-recovery-owned")
            )
            let quarantinedUnknownData = Data("quarantined unknown".utf8)
            try quarantinedUnknownData.write(to: recoveryURL)
            guard case let .failed(.recoveryRequired(record))? = await recoveryStore.remove(recoveryItem.id)?.outcome else {
                throw FileHoldError.cleanupFailed
            }
            check(
                record.accounting.exactByteCount == Int64(quarantinedUnknownData.count),
                "single-link regular recovery records the quarantined replacement's exact size"
            )
            check(
                FileManager.default.fileExists(atPath: recoveryRoot.appendingPathComponent(record.relativeName).path),
                "restore collision exposes a recoverable quarantine path"
            )
            check(
                await recoveryStore.remove(recoveryItem.id)?.outcome == .failed(.recoveryRequired(record)),
                "ordinary retry preserves the recovery signal"
            )
            check(await recoveryStore.recoveryEntries().count == 1, "recovery state remains explicitly enumerable")
            let recoveryFollowup = sandbox.appendingPathComponent("recovery-followup")
            try Data(repeating: 0x52, count: 64).write(to: recoveryFollowup)
            check(
                (await recoveryStore.ingest(
                    [recoveryFollowup],
                    options: .init(mode: .temporaryCopy)
                )).heldItems.count == 1,
                "recovery capacity charges quarantined bytes rather than the inspected source"
            )
            _ = try await recoveryStore.acknowledgeRecovery(for: recoveryItem.id)
            check(await recoveryStore.recoveryEntries().isEmpty, "only explicit acknowledgement clears recovery state")
            check(
                FileManager.default.fileExists(atPath: recoveryRoot.appendingPathComponent(record.relativeName).path),
                "acknowledgement never silently deletes quarantined unknown data"
            )

            let uncommittedRoot = sandbox.appendingPathComponent("uncommitted-recovery-root")
            let uncommittedPublishObserver = PublishGateObserver()
            let uncommittedStorageObserver = QuarantineCollisionObserver(root: uncommittedRoot)
            let uncommittedStore = try makeStore(
                root: uncommittedRoot,
                copyObserver: uncommittedPublishObserver,
                storageObserver: uncommittedStorageObserver,
                idPrefix: "uncommitted-recovery"
            )
            let uncommittedIngest = Task {
                await uncommittedStore.ingest([source], options: .init(mode: .temporaryCopy))
            }
            let uncommittedName = await uncommittedPublishObserver.waitUntilPublished()
            let uncommittedURL = uncommittedRoot.appendingPathComponent(uncommittedName)
            try FileManager.default.moveItem(
                at: uncommittedURL,
                to: uncommittedRoot.appendingPathComponent("displaced-uncommitted-owned")
            )
            try Data("uncommitted unknown".utf8).write(to: uncommittedURL)
            let uncommittedShutdown = Task { try await uncommittedStore.shutdown() }
            await yieldSeveralTimes()
            await uncommittedPublishObserver.release()
            let uncommittedReport = await uncommittedIngest.value
            guard case let .recoveryRequired(uncommittedRecord)? = failure(
                of: uncommittedReport,
                at: 0
            ) else {
                throw FileHoldError.cleanupFailed
            }
            check(
                uncommittedRecord.accounting.exactByteCount
                    == Int64(Data("uncommitted unknown".utf8).count),
                "uncommitted regular recovery accounting records exact quarantined bytes"
            )
            let uncommittedShutdownReport = try await uncommittedShutdown.value
            check(
                uncommittedShutdownReport.recoveryEntries.map(\.record)
                    == [uncommittedRecord],
                "shutdown reports uncommitted quarantine recovery"
            )
            check(
                FileManager.default.fileExists(
                    atPath: uncommittedRoot.appendingPathComponent(uncommittedRecord.relativeName).path
                ),
                "shutdown never deletes an uncommitted unknown quarantine"
            )

            let directorySentinel = sandbox.appendingPathComponent("directory-outside-sentinel")
            let directorySentinelData = Data("outside must remain untouched".utf8)
            try directorySentinelData.write(to: directorySentinel)
            let untrustedTreeBytes: UInt64 = 2 * 1_024 * 1_024

            let restoredDirectoryRoot = sandbox.appendingPathComponent("restored-directory-root")
            let restoredDirectoryStore = try makeStore(
                root: restoredDirectoryRoot,
                idPrefix: "restored-directory"
            )
            let restoredDirectoryItem = try requireHeld(
                await restoredDirectoryStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy)
                ),
                at: 0
            )
            let restoredDirectoryURL = restoredDirectoryRoot.appendingPathComponent(
                relativeName(of: restoredDirectoryItem)
            )
            try FileManager.default.moveItem(
                at: restoredDirectoryURL,
                to: restoredDirectoryRoot.appendingPathComponent("displaced-restored-directory-owned")
            )
            try createUntrustedDirectoryTree(
                at: restoredDirectoryURL,
                payloadByteCount: untrustedTreeBytes,
                externalLinkTarget: directorySentinel
            )
            check(
                await restoredDirectoryStore.remove(restoredDirectoryItem.id)?.outcome
                    == .failed(.unsafeStorage),
                "committed directory substitution restores successfully without deletion"
            )
            check(
                try fileSize(untrustedTreePayload(at: restoredDirectoryURL)) == untrustedTreeBytes,
                "successful restoration preserves the committed nested tree"
            )
            check(
                await restoredDirectoryStore.remove(restoredDirectoryItem.id)?.outcome
                    == .failed(.unsafeStorage),
                "repeated committed cleanup keeps restoring the unknown tree"
            )
            check(
                await restoredDirectoryStore.recoveryEntries().isEmpty,
                "successful restoration does not claim a stranded quarantine"
            )
            do {
                _ = try await restoredDirectoryStore.acknowledgeRecovery(
                    for: restoredDirectoryItem.id
                )
                recordFailure("successfully restored content cannot be falsely acknowledged")
            } catch FileHoldError.itemNotFound {
                check(true, "successful restoration exposes no false recovery acknowledgement")
            }

            let directoryRecoveryRoot = sandbox.appendingPathComponent("directory-recovery-root")
            let directoryRecoveryObserver = QuarantineCollisionObserver(root: directoryRecoveryRoot)
            let directoryRecoveryStore = try makeStore(
                root: directoryRecoveryRoot,
                limits: FileHoldIngestLimits(
                    maximumItemCount: 2,
                    maximumItemBytes: 512 * 1_024,
                    maximumTotalBytes: 512 * 1_024
                ),
                storageObserver: directoryRecoveryObserver,
                idPrefix: "directory-recovery"
            )
            let directoryRecoveryItem = try requireHeld(
                await directoryRecoveryStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy)
                ),
                at: 0
            )
            let directoryRecoveryURL = directoryRecoveryRoot.appendingPathComponent(
                relativeName(of: directoryRecoveryItem)
            )
            try FileManager.default.moveItem(
                at: directoryRecoveryURL,
                to: directoryRecoveryRoot.appendingPathComponent("displaced-directory-recovery-owned")
            )
            try createUntrustedDirectoryTree(
                at: directoryRecoveryURL,
                payloadByteCount: untrustedTreeBytes,
                externalLinkTarget: directorySentinel
            )
            guard case let .failed(.recoveryRequired(directoryRecord))?
                = await directoryRecoveryStore.remove(directoryRecoveryItem.id)?.outcome else {
                throw FileHoldError.cleanupFailed
            }
            check(
                directoryRecord.accounting == .unquantifiable,
                "stranded directory recovery is explicitly unquantifiable"
            )
            let quarantinedDirectoryURL = directoryRecoveryRoot.appendingPathComponent(
                directoryRecord.relativeName
            )
            check(
                try fileSize(untrustedTreePayload(at: quarantinedDirectoryURL))
                    == untrustedTreeBytes,
                "failed restoration preserves the full committed nested tree"
            )
            check(
                try Data(contentsOf: directorySentinel) == directorySentinelData,
                "recovery accounting never follows a nested untrusted link"
            )
            let directoryCapacitySource = sandbox.appendingPathComponent("directory-capacity-source")
            try Data(repeating: 0x44, count: 64).write(to: directoryCapacitySource)
            check(
                failure(
                    of: await directoryRecoveryStore.ingest(
                        [directoryCapacitySource],
                        options: .init(mode: .temporaryCopy)
                    ),
                    at: 0
                ) == .totalSizeExceeded(maximumBytes: 512 * 1_024),
                "unquantifiable committed recovery blocks all byte admission"
            )
            check(
                await directoryRecoveryStore.remove(directoryRecoveryItem.id)?.outcome
                    == .failed(.recoveryRequired(directoryRecord)),
                "repeated committed cleanup preserves unquantifiable recovery"
            )
            _ = try await directoryRecoveryStore.acknowledgeRecovery(
                for: directoryRecoveryItem.id
            )
            check(
                await directoryRecoveryStore.recoveryEntries().isEmpty,
                "explicit acknowledgement clears committed unquantifiable accounting"
            )
            check(
                try fileSize(untrustedTreePayload(at: quarantinedDirectoryURL))
                    == untrustedTreeBytes,
                "committed acknowledgement never speculatively deletes the unknown tree"
            )
            check(
                (await directoryRecoveryStore.ingest(
                    [directoryCapacitySource],
                    options: .init(mode: .temporaryCopy)
                )).heldItems.count == 1,
                "committed admission resumes only after recovery acknowledgement"
            )

            let restoredUncommittedRoot = sandbox.appendingPathComponent(
                "restored-uncommitted-directory-root"
            )
            let restoredUncommittedObserver = PublishGateObserver()
            let restoredUncommittedStore = try makeStore(
                root: restoredUncommittedRoot,
                copyObserver: restoredUncommittedObserver,
                idPrefix: "restored-uncommitted-directory"
            )
            let restoredUncommittedIngest = Task {
                await restoredUncommittedStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy)
                )
            }
            let restoredUncommittedName = await restoredUncommittedObserver.waitUntilPublished()
            let restoredUncommittedURL = restoredUncommittedRoot.appendingPathComponent(
                restoredUncommittedName
            )
            try FileManager.default.moveItem(
                at: restoredUncommittedURL,
                to: restoredUncommittedRoot.appendingPathComponent(
                    "displaced-restored-uncommitted-owned"
                )
            )
            try createUntrustedDirectoryTree(
                at: restoredUncommittedURL,
                payloadByteCount: untrustedTreeBytes,
                externalLinkTarget: directorySentinel
            )
            await restoredUncommittedObserver.release()
            check(
                failure(of: await restoredUncommittedIngest.value, at: 0) == .unsafeStorage,
                "uncommitted directory substitution reports safe restoration"
            )
            check(
                try fileSize(untrustedTreePayload(at: restoredUncommittedURL))
                    == untrustedTreeBytes,
                "successful uncommitted restoration preserves the nested tree"
            )
            check(
                await restoredUncommittedStore.recoveryEntries().isEmpty,
                "successful uncommitted restoration creates no stranded recovery"
            )

            let uncommittedDirectoryRoot = sandbox.appendingPathComponent(
                "uncommitted-directory-recovery-root"
            )
            let uncommittedDirectoryPublishObserver = PublishGateObserver()
            let uncommittedDirectoryStorageObserver = QuarantineCollisionObserver(
                root: uncommittedDirectoryRoot
            )
            let uncommittedDirectoryStore = try makeStore(
                root: uncommittedDirectoryRoot,
                limits: FileHoldIngestLimits(
                    maximumItemCount: 2,
                    maximumItemBytes: 512 * 1_024,
                    maximumTotalBytes: 512 * 1_024
                ),
                copyObserver: uncommittedDirectoryPublishObserver,
                storageObserver: uncommittedDirectoryStorageObserver,
                idPrefix: "uncommitted-directory-recovery"
            )
            let uncommittedDirectoryIngest = Task {
                await uncommittedDirectoryStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy)
                )
            }
            let uncommittedDirectoryName = await uncommittedDirectoryPublishObserver
                .waitUntilPublished()
            let uncommittedDirectoryURL = uncommittedDirectoryRoot.appendingPathComponent(
                uncommittedDirectoryName
            )
            try FileManager.default.moveItem(
                at: uncommittedDirectoryURL,
                to: uncommittedDirectoryRoot.appendingPathComponent(
                    "displaced-uncommitted-directory-owned"
                )
            )
            try createUntrustedDirectoryTree(
                at: uncommittedDirectoryURL,
                payloadByteCount: untrustedTreeBytes,
                externalLinkTarget: directorySentinel
            )
            await uncommittedDirectoryPublishObserver.release()
            let uncommittedDirectoryReport = await uncommittedDirectoryIngest.value
            guard case let .recoveryRequired(uncommittedDirectoryRecord)? = failure(
                of: uncommittedDirectoryReport,
                at: 0
            ), let uncommittedDirectoryEntry = await uncommittedDirectoryStore
                .recoveryEntries().first else {
                throw FileHoldError.cleanupFailed
            }
            check(
                uncommittedDirectoryRecord.accounting == .unquantifiable,
                "stranded uncommitted directory recovery is unquantifiable"
            )
            let uncommittedQuarantineURL = uncommittedDirectoryRoot.appendingPathComponent(
                uncommittedDirectoryRecord.relativeName
            )
            check(
                try fileSize(untrustedTreePayload(at: uncommittedQuarantineURL))
                    == untrustedTreeBytes,
                "failed uncommitted restoration preserves the nested tree"
            )
            check(
                failure(
                    of: await uncommittedDirectoryStore.ingest(
                        [directoryCapacitySource],
                        options: .init(mode: .temporaryCopy)
                    ),
                    at: 0
                ) == .totalSizeExceeded(maximumBytes: 512 * 1_024),
                "unquantifiable uncommitted recovery blocks all byte admission"
            )
            check(
                await uncommittedDirectoryStore.remove(uncommittedDirectoryEntry.itemID) == nil,
                "ordinary remove cannot erase uncommitted directory recovery"
            )
            check(
                await uncommittedDirectoryStore.recoveryEntries().map(\.record)
                    == [uncommittedDirectoryRecord],
                "repeated uncommitted cleanup lookup preserves the recovery signal"
            )
            _ = try await uncommittedDirectoryStore.acknowledgeRecovery(
                for: uncommittedDirectoryEntry.itemID
            )
            check(
                await uncommittedDirectoryStore.recoveryEntries().isEmpty,
                "explicit acknowledgement clears uncommitted unquantifiable accounting"
            )
            check(
                try fileSize(untrustedTreePayload(at: uncommittedQuarantineURL))
                    == untrustedTreeBytes,
                "uncommitted acknowledgement never deletes the unknown tree"
            )
            check(
                (await uncommittedDirectoryStore.ingest(
                    [directoryCapacitySource],
                    options: .init(mode: .temporaryCopy)
                )).heldItems.count == 1,
                "uncommitted admission resumes only after explicit acknowledgement"
            )
            check(
                try Data(contentsOf: directorySentinel) == directorySentinelData,
                "all directory recovery paths preserve external link targets"
            )

            let movedCommittedRoot = sandbox.appendingPathComponent(
                "moved-committed-recovery-root"
            )
            let movedCommittedObserver = MovedQuarantineCollisionObserver(
                root: movedCommittedRoot,
                movedRelativeName: "relocated-committed-tree"
            )
            let movedCommittedStore = try makeStore(
                root: movedCommittedRoot,
                limits: FileHoldIngestLimits(
                    maximumItemCount: 2,
                    maximumItemBytes: 512 * 1_024,
                    maximumTotalBytes: 512 * 1_024
                ),
                storageObserver: movedCommittedObserver,
                idPrefix: "moved-committed-recovery"
            )
            let movedCommittedItem = try requireHeld(
                await movedCommittedStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy)
                ),
                at: 0
            )
            let movedCommittedOriginalURL = movedCommittedRoot.appendingPathComponent(
                relativeName(of: movedCommittedItem)
            )
            let movedCommittedOwnedURL = movedCommittedRoot.appendingPathComponent(
                "displaced-moved-committed-owned"
            )
            try FileManager.default.moveItem(
                at: movedCommittedOriginalURL,
                to: movedCommittedOwnedURL
            )
            try createUntrustedDirectoryTree(
                at: movedCommittedOriginalURL,
                payloadByteCount: untrustedTreeBytes,
                externalLinkTarget: directorySentinel
            )
            let movedCommittedOtherURL = movedCommittedRoot.appendingPathComponent(
                "committed-other-name"
            )
            let movedCommittedOtherData = Data("committed other must remain".utf8)
            try movedCommittedOtherData.write(to: movedCommittedOtherURL)
            let movedCommittedSourceData = try Data(contentsOf: source)
            guard case let .failed(.recoveryRequired(movedCommittedRecord))?
                = await movedCommittedStore.remove(movedCommittedItem.id)?.outcome else {
                throw FileHoldError.cleanupFailed
            }
            check(
                movedCommittedObserver.moveSucceeded,
                "committed observer moves the quarantine before recovery inspection"
            )
            check(
                movedCommittedRecord.locator
                    == .lastKnownRelativeName(movedCommittedRecord.relativeName),
                "missing committed quarantine records only its last-known owned locator"
            )
            check(
                movedCommittedRecord.accounting == .unquantifiable,
                "missing committed quarantine fails closed as unquantifiable"
            )
            check(
                !FileManager.default.fileExists(
                    atPath: movedCommittedRoot.appendingPathComponent(
                        movedCommittedRecord.relativeName
                    ).path
                ),
                "committed recovery never guesses a replacement for the missing locator"
            )
            let movedCommittedTreeURL = movedCommittedRoot.appendingPathComponent(
                movedCommittedObserver.movedRelativeName
            )
            check(
                try fileSize(untrustedTreePayload(at: movedCommittedTreeURL))
                    == untrustedTreeBytes,
                "committed moved quarantine preserves its full nested tree"
            )
            check(
                try Data(contentsOf: movedCommittedOriginalURL)
                    == Data("restore blocker".utf8),
                "committed recovery preserves the restore blocker"
            )
            check(
                try Data(contentsOf: movedCommittedOwnedURL) == movedCommittedSourceData,
                "committed recovery preserves the displaced owned copy"
            )
            check(
                try Data(contentsOf: movedCommittedOtherURL) == movedCommittedOtherData,
                "committed recovery leaves other root names untouched"
            )
            check(
                try Data(contentsOf: source) == movedCommittedSourceData,
                "committed moved recovery leaves the source untouched"
            )
            check(
                failure(
                    of: await movedCommittedStore.ingest(
                        [directoryCapacitySource],
                        options: .init(mode: .temporaryCopy)
                    ),
                    at: 0
                ) == .totalSizeExceeded(maximumBytes: 512 * 1_024),
                "missing committed quarantine blocks byte admission"
            )
            check(
                await movedCommittedStore.remove(movedCommittedItem.id)?.outcome
                    == .failed(.recoveryRequired(movedCommittedRecord)),
                "repeated committed cleanup preserves missing-quarantine recovery"
            )
            check(
                await movedCommittedStore.recoveryEntries().map(\.record)
                    == [movedCommittedRecord],
                "committed moved-quarantine recovery remains enumerable"
            )
            _ = try await movedCommittedStore.acknowledgeRecovery(
                for: movedCommittedItem.id
            )
            check(
                await movedCommittedStore.recoveryEntries().isEmpty,
                "committed moved recovery clears only on acknowledgement"
            )
            check(
                try fileSize(untrustedTreePayload(at: movedCommittedTreeURL))
                    == untrustedTreeBytes,
                "committed acknowledgement never deletes relocated content"
            )
            check(
                try Data(contentsOf: movedCommittedOriginalURL)
                    == Data("restore blocker".utf8)
                    && Data(contentsOf: movedCommittedOwnedURL) == movedCommittedSourceData
                    && Data(contentsOf: movedCommittedOtherURL) == movedCommittedOtherData
                    && Data(contentsOf: source) == movedCommittedSourceData,
                "committed acknowledgement leaves source and all other names untouched"
            )
            check(
                (await movedCommittedStore.ingest(
                    [directoryCapacitySource],
                    options: .init(mode: .temporaryCopy)
                )).heldItems.count == 1,
                "committed admission resumes after moved recovery acknowledgement"
            )

            let movedUncommittedRoot = sandbox.appendingPathComponent(
                "moved-uncommitted-recovery-root"
            )
            let movedUncommittedPublishObserver = PublishGateObserver()
            let movedUncommittedStorageObserver = MovedQuarantineCollisionObserver(
                root: movedUncommittedRoot,
                movedRelativeName: "relocated-uncommitted-tree"
            )
            let movedUncommittedStore = try makeStore(
                root: movedUncommittedRoot,
                limits: FileHoldIngestLimits(
                    maximumItemCount: 2,
                    maximumItemBytes: 512 * 1_024,
                    maximumTotalBytes: 512 * 1_024
                ),
                copyObserver: movedUncommittedPublishObserver,
                storageObserver: movedUncommittedStorageObserver,
                idPrefix: "moved-uncommitted-recovery"
            )
            let movedUncommittedOtherURL = movedUncommittedRoot.appendingPathComponent(
                "uncommitted-other-name"
            )
            let movedUncommittedOtherData = Data("uncommitted other must remain".utf8)
            try movedUncommittedOtherData.write(to: movedUncommittedOtherURL)
            let movedUncommittedSourceData = try Data(contentsOf: source)
            let movedUncommittedIngest = Task {
                await movedUncommittedStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy)
                )
            }
            let movedUncommittedName = await movedUncommittedPublishObserver
                .waitUntilPublished()
            let movedUncommittedOriginalURL = movedUncommittedRoot.appendingPathComponent(
                movedUncommittedName
            )
            let movedUncommittedOwnedURL = movedUncommittedRoot.appendingPathComponent(
                "displaced-moved-uncommitted-owned"
            )
            try FileManager.default.moveItem(
                at: movedUncommittedOriginalURL,
                to: movedUncommittedOwnedURL
            )
            try createUntrustedDirectoryTree(
                at: movedUncommittedOriginalURL,
                payloadByteCount: untrustedTreeBytes,
                externalLinkTarget: directorySentinel
            )
            await movedUncommittedPublishObserver.release()
            let movedUncommittedReport = await movedUncommittedIngest.value
            guard case let .recoveryRequired(movedUncommittedRecord)? = failure(
                of: movedUncommittedReport,
                at: 0
            ), let movedUncommittedEntry = await movedUncommittedStore
                .recoveryEntries().first else {
                throw FileHoldError.cleanupFailed
            }
            check(
                movedUncommittedStorageObserver.moveSucceeded,
                "uncommitted observer moves the quarantine before recovery inspection"
            )
            check(
                movedUncommittedRecord.locator
                    == .lastKnownRelativeName(movedUncommittedRecord.relativeName),
                "missing uncommitted quarantine records only its last-known owned locator"
            )
            check(
                movedUncommittedRecord.accounting == .unquantifiable,
                "missing uncommitted quarantine fails closed as unquantifiable"
            )
            check(
                !FileManager.default.fileExists(
                    atPath: movedUncommittedRoot.appendingPathComponent(
                        movedUncommittedRecord.relativeName
                    ).path
                ),
                "uncommitted recovery never guesses a replacement for the missing locator"
            )
            let movedUncommittedTreeURL = movedUncommittedRoot.appendingPathComponent(
                movedUncommittedStorageObserver.movedRelativeName
            )
            check(
                try fileSize(untrustedTreePayload(at: movedUncommittedTreeURL))
                    == untrustedTreeBytes,
                "uncommitted moved quarantine preserves its full nested tree"
            )
            check(
                try Data(contentsOf: movedUncommittedOriginalURL)
                    == Data("restore blocker".utf8),
                "uncommitted recovery preserves the restore blocker"
            )
            check(
                try Data(contentsOf: movedUncommittedOwnedURL) == movedUncommittedSourceData,
                "uncommitted recovery preserves the displaced owned copy"
            )
            check(
                try Data(contentsOf: movedUncommittedOtherURL) == movedUncommittedOtherData,
                "uncommitted recovery leaves other root names untouched"
            )
            check(
                try Data(contentsOf: source) == movedUncommittedSourceData,
                "uncommitted moved recovery leaves the source untouched"
            )
            check(
                failure(
                    of: await movedUncommittedStore.ingest(
                        [directoryCapacitySource],
                        options: .init(mode: .temporaryCopy)
                    ),
                    at: 0
                ) == .totalSizeExceeded(maximumBytes: 512 * 1_024),
                "missing uncommitted quarantine blocks byte admission"
            )
            check(
                await movedUncommittedStore.remove(movedUncommittedEntry.itemID) == nil,
                "ordinary remove cannot erase moved uncommitted recovery"
            )
            check(
                await movedUncommittedStore.recoveryEntries().map(\.record)
                    == [movedUncommittedRecord],
                "uncommitted moved-quarantine recovery remains enumerable"
            )
            _ = try await movedUncommittedStore.acknowledgeRecovery(
                for: movedUncommittedEntry.itemID
            )
            check(
                await movedUncommittedStore.recoveryEntries().isEmpty,
                "uncommitted moved recovery clears only on acknowledgement"
            )
            check(
                try fileSize(untrustedTreePayload(at: movedUncommittedTreeURL))
                    == untrustedTreeBytes,
                "uncommitted acknowledgement never deletes relocated content"
            )
            check(
                try Data(contentsOf: movedUncommittedOriginalURL)
                    == Data("restore blocker".utf8)
                    && Data(contentsOf: movedUncommittedOwnedURL) == movedUncommittedSourceData
                    && Data(contentsOf: movedUncommittedOtherURL) == movedUncommittedOtherData
                    && Data(contentsOf: source) == movedUncommittedSourceData,
                "uncommitted acknowledgement leaves source and all other names untouched"
            )
            check(
                (await movedUncommittedStore.ingest(
                    [directoryCapacitySource],
                    options: .init(mode: .temporaryCopy)
                )).heldItems.count == 1,
                "uncommitted admission resumes after moved recovery acknowledgement"
            )
            check(
                try Data(contentsOf: directorySentinel) == directorySentinelData,
                "moved recovery paths never follow nested external links"
            )

            let reusedCommittedRoot = sandbox.appendingPathComponent(
                "reused-committed-recovery-root"
            )
            let reusedCommittedReplacement = Data("tiny committed Q".utf8)
            let reusedCommittedObserver = MoveAndReplaceQuarantineObserver(
                root: reusedCommittedRoot,
                movedRelativeName: "relocated-reused-committed-tree",
                replacementData: reusedCommittedReplacement
            )
            let reusedCommittedStore = try makeStore(
                root: reusedCommittedRoot,
                limits: FileHoldIngestLimits(
                    maximumItemCount: 2,
                    maximumItemBytes: 512 * 1_024,
                    maximumTotalBytes: 512 * 1_024
                ),
                storageObserver: reusedCommittedObserver,
                idPrefix: "reused-committed-recovery"
            )
            let reusedCommittedItem = try requireHeld(
                await reusedCommittedStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy)
                ),
                at: 0
            )
            let reusedCommittedOriginalURL = reusedCommittedRoot.appendingPathComponent(
                relativeName(of: reusedCommittedItem)
            )
            let reusedCommittedOwnedURL = reusedCommittedRoot.appendingPathComponent(
                "displaced-reused-committed-owned"
            )
            try FileManager.default.moveItem(
                at: reusedCommittedOriginalURL,
                to: reusedCommittedOwnedURL
            )
            try createUntrustedDirectoryTree(
                at: reusedCommittedOriginalURL,
                payloadByteCount: untrustedTreeBytes,
                externalLinkTarget: directorySentinel
            )
            let reusedCommittedOtherURL = reusedCommittedRoot.appendingPathComponent(
                "reused-committed-other"
            )
            let reusedCommittedOtherData = Data("reused committed other".utf8)
            try reusedCommittedOtherData.write(to: reusedCommittedOtherURL)
            let reusedCommittedSourceData = try Data(contentsOf: source)
            guard case let .failed(.recoveryRequired(reusedCommittedRecord))?
                = await reusedCommittedStore.remove(reusedCommittedItem.id)?.outcome else {
                throw FileHoldError.cleanupFailed
            }
            let reusedCommittedQuarantineURL = reusedCommittedRoot.appendingPathComponent(
                reusedCommittedRecord.relativeName
            )
            let reusedCommittedTreeURL = reusedCommittedRoot.appendingPathComponent(
                reusedCommittedObserver.movedRelativeName
            )
            check(
                reusedCommittedObserver.mutationSucceeded,
                "committed observer deterministically moves and reuses the quarantine name"
            )
            check(
                reusedCommittedRecord.locator
                    == .lastKnownRelativeName(reusedCommittedRecord.relativeName),
                "committed quarantine name reuse cannot be classified as exact"
            )
            check(
                reusedCommittedRecord.accounting == .unquantifiable,
                "committed quarantine name reuse blocks accounting fail closed"
            )
            check(
                try Data(contentsOf: reusedCommittedQuarantineURL)
                    == reusedCommittedReplacement,
                "committed recovery preserves the materially smaller Q replacement"
            )
            check(
                try fileSize(untrustedTreePayload(at: reusedCommittedTreeURL))
                    == untrustedTreeBytes,
                "committed recovery preserves the relocated large tree"
            )
            check(
                try Data(contentsOf: reusedCommittedOriginalURL)
                    == Data("restore blocker".utf8),
                "committed reused-name recovery preserves the restore blocker"
            )
            check(
                try Data(contentsOf: reusedCommittedOwnedURL) == reusedCommittedSourceData,
                "committed reused-name recovery preserves displaced owned evidence"
            )
            check(
                try Data(contentsOf: reusedCommittedOtherURL) == reusedCommittedOtherData
                    && Data(contentsOf: source) == reusedCommittedSourceData,
                "committed reused-name recovery leaves source and unrelated evidence untouched"
            )
            check(
                failure(
                    of: await reusedCommittedStore.ingest(
                        [directoryCapacitySource],
                        options: .init(mode: .temporaryCopy)
                    ),
                    at: 0
                ) == .totalSizeExceeded(maximumBytes: 512 * 1_024),
                "tiny committed Q replacement cannot reopen byte admission"
            )
            check(
                await reusedCommittedStore.remove(reusedCommittedItem.id)?.outcome
                    == .failed(.recoveryRequired(reusedCommittedRecord)),
                "repeated committed cleanup preserves reused-name recovery"
            )
            check(
                await reusedCommittedStore.recoveryEntries().map(\.record)
                    == [reusedCommittedRecord],
                "committed reused-name recovery remains enumerable"
            )
            check(
                try Data(contentsOf: reusedCommittedQuarantineURL)
                    == reusedCommittedReplacement
                    && fileSize(untrustedTreePayload(at: reusedCommittedTreeURL))
                        == untrustedTreeBytes,
                "repeated committed cleanup never mutates Q or relocated content"
            )
            _ = try await reusedCommittedStore.acknowledgeRecovery(
                for: reusedCommittedItem.id
            )
            check(
                await reusedCommittedStore.recoveryEntries().isEmpty,
                "committed reused-name recovery clears only on acknowledgement"
            )
            check(
                try Data(contentsOf: reusedCommittedQuarantineURL)
                    == reusedCommittedReplacement
                    && fileSize(untrustedTreePayload(at: reusedCommittedTreeURL))
                        == untrustedTreeBytes
                    && Data(contentsOf: reusedCommittedOriginalURL)
                        == Data("restore blocker".utf8)
                    && Data(contentsOf: reusedCommittedOwnedURL) == reusedCommittedSourceData
                    && Data(contentsOf: reusedCommittedOtherURL) == reusedCommittedOtherData
                    && Data(contentsOf: source) == reusedCommittedSourceData,
                "committed acknowledgement preserves every unknown and evidence file"
            )
            check(
                (await reusedCommittedStore.ingest(
                    [directoryCapacitySource],
                    options: .init(mode: .temporaryCopy)
                )).heldItems.count == 1,
                "committed reused-name admission resumes only after acknowledgement"
            )

            let reusedUncommittedRoot = sandbox.appendingPathComponent(
                "reused-uncommitted-recovery-root"
            )
            let reusedUncommittedReplacement = Data("tiny uncommitted Q".utf8)
            let reusedUncommittedPublishObserver = PublishGateObserver()
            let reusedUncommittedStorageObserver = MoveAndReplaceQuarantineObserver(
                root: reusedUncommittedRoot,
                movedRelativeName: "relocated-reused-uncommitted-tree",
                replacementData: reusedUncommittedReplacement
            )
            let reusedUncommittedStore = try makeStore(
                root: reusedUncommittedRoot,
                limits: FileHoldIngestLimits(
                    maximumItemCount: 2,
                    maximumItemBytes: 512 * 1_024,
                    maximumTotalBytes: 512 * 1_024
                ),
                copyObserver: reusedUncommittedPublishObserver,
                storageObserver: reusedUncommittedStorageObserver,
                idPrefix: "reused-uncommitted-recovery"
            )
            let reusedUncommittedOtherURL = reusedUncommittedRoot.appendingPathComponent(
                "reused-uncommitted-other"
            )
            let reusedUncommittedOtherData = Data("reused uncommitted other".utf8)
            try reusedUncommittedOtherData.write(to: reusedUncommittedOtherURL)
            let reusedUncommittedSourceData = try Data(contentsOf: source)
            let reusedUncommittedIngest = Task {
                await reusedUncommittedStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy)
                )
            }
            let reusedUncommittedName = await reusedUncommittedPublishObserver
                .waitUntilPublished()
            let reusedUncommittedOriginalURL = reusedUncommittedRoot.appendingPathComponent(
                reusedUncommittedName
            )
            let reusedUncommittedOwnedURL = reusedUncommittedRoot.appendingPathComponent(
                "displaced-reused-uncommitted-owned"
            )
            try FileManager.default.moveItem(
                at: reusedUncommittedOriginalURL,
                to: reusedUncommittedOwnedURL
            )
            try createUntrustedDirectoryTree(
                at: reusedUncommittedOriginalURL,
                payloadByteCount: untrustedTreeBytes,
                externalLinkTarget: directorySentinel
            )
            await reusedUncommittedPublishObserver.release()
            let reusedUncommittedReport = await reusedUncommittedIngest.value
            guard case let .recoveryRequired(reusedUncommittedRecord)? = failure(
                of: reusedUncommittedReport,
                at: 0
            ), let reusedUncommittedEntry = await reusedUncommittedStore
                .recoveryEntries().first else {
                throw FileHoldError.cleanupFailed
            }
            let reusedUncommittedQuarantineURL = reusedUncommittedRoot.appendingPathComponent(
                reusedUncommittedRecord.relativeName
            )
            let reusedUncommittedTreeURL = reusedUncommittedRoot.appendingPathComponent(
                reusedUncommittedStorageObserver.movedRelativeName
            )
            check(
                reusedUncommittedStorageObserver.mutationSucceeded,
                "uncommitted observer deterministically moves and reuses the quarantine name"
            )
            check(
                reusedUncommittedRecord.locator
                    == .lastKnownRelativeName(reusedUncommittedRecord.relativeName),
                "uncommitted quarantine name reuse cannot be classified as exact"
            )
            check(
                reusedUncommittedRecord.accounting == .unquantifiable,
                "uncommitted quarantine name reuse blocks accounting fail closed"
            )
            check(
                try Data(contentsOf: reusedUncommittedQuarantineURL)
                    == reusedUncommittedReplacement,
                "uncommitted recovery preserves the materially smaller Q replacement"
            )
            check(
                try fileSize(untrustedTreePayload(at: reusedUncommittedTreeURL))
                    == untrustedTreeBytes,
                "uncommitted recovery preserves the relocated large tree"
            )
            check(
                try Data(contentsOf: reusedUncommittedOriginalURL)
                    == Data("restore blocker".utf8),
                "uncommitted reused-name recovery preserves the restore blocker"
            )
            check(
                try Data(contentsOf: reusedUncommittedOwnedURL) == reusedUncommittedSourceData,
                "uncommitted reused-name recovery preserves displaced owned evidence"
            )
            check(
                try Data(contentsOf: reusedUncommittedOtherURL) == reusedUncommittedOtherData
                    && Data(contentsOf: source) == reusedUncommittedSourceData,
                "uncommitted reused-name recovery leaves source and unrelated evidence untouched"
            )
            check(
                failure(
                    of: await reusedUncommittedStore.ingest(
                        [directoryCapacitySource],
                        options: .init(mode: .temporaryCopy)
                    ),
                    at: 0
                ) == .totalSizeExceeded(maximumBytes: 512 * 1_024),
                "tiny uncommitted Q replacement cannot reopen byte admission"
            )
            check(
                await reusedUncommittedStore.remove(reusedUncommittedEntry.itemID) == nil,
                "ordinary remove cannot erase reused-name uncommitted recovery"
            )
            check(
                await reusedUncommittedStore.recoveryEntries().map(\.record)
                    == [reusedUncommittedRecord],
                "uncommitted reused-name recovery remains enumerable"
            )
            check(
                try Data(contentsOf: reusedUncommittedQuarantineURL)
                    == reusedUncommittedReplacement
                    && fileSize(untrustedTreePayload(at: reusedUncommittedTreeURL))
                        == untrustedTreeBytes,
                "repeated uncommitted cleanup never mutates Q or relocated content"
            )
            _ = try await reusedUncommittedStore.acknowledgeRecovery(
                for: reusedUncommittedEntry.itemID
            )
            check(
                await reusedUncommittedStore.recoveryEntries().isEmpty,
                "uncommitted reused-name recovery clears only on acknowledgement"
            )
            check(
                try Data(contentsOf: reusedUncommittedQuarantineURL)
                    == reusedUncommittedReplacement
                    && fileSize(untrustedTreePayload(at: reusedUncommittedTreeURL))
                        == untrustedTreeBytes
                    && Data(contentsOf: reusedUncommittedOriginalURL)
                        == Data("restore blocker".utf8)
                    && Data(contentsOf: reusedUncommittedOwnedURL)
                        == reusedUncommittedSourceData
                    && Data(contentsOf: reusedUncommittedOtherURL)
                        == reusedUncommittedOtherData
                    && Data(contentsOf: source) == reusedUncommittedSourceData,
                "uncommitted acknowledgement preserves every unknown and evidence file"
            )
            check(
                (await reusedUncommittedStore.ingest(
                    [directoryCapacitySource],
                    options: .init(mode: .temporaryCopy)
                )).heldItems.count == 1,
                "uncommitted reused-name admission resumes only after acknowledgement"
            )
            check(
                try Data(contentsOf: directorySentinel) == directorySentinelData,
                "move-and-replace recovery never follows nested external links"
            )

            let unicodeObserver = GatedCopyObserver()
            let unicodeRoot = sandbox.appendingPathComponent("unicode-stage-root")
            let unicodeID = HeldFileID(rawValue: String(repeating: "é", count: 300))
            let unicodeStore = try makeStore(
                root: unicodeRoot,
                copyObserver: unicodeObserver,
                makeID: { unicodeID },
                idPrefix: "unused"
            )
            let unicodeTask = Task {
                await unicodeStore.ingest([source], options: .init(mode: .temporaryCopy))
            }
            await unicodeObserver.waitUntilReached()
            guard let unicodeStage = try directoryNames(unicodeRoot).first(where: {
                $0.hasPrefix(".erylo-stage-")
            }) else {
                throw FileHoldError.copyFailed
            }
            check(unicodeStage.utf8.count <= 200, "entire Unicode-derived stage component is byte bounded")
            await unicodeObserver.release()
            _ = await unicodeTask.value
        } catch {
            recordUnexpected(error, test: "adversarial copy/recovery boundary")
        }
    }

    mutating func verifyExpiryLimitsShutdownAndHistory() async {
        guard let sandbox = try? makeSandbox("expiry-limits-shutdown") else {
            recordFailure("expiry/limits/shutdown setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            var invalidLimits: [FileHoldIngestLimits] = []
            var candidate = FileHoldIngestLimits()
            candidate.maximumInputCount = FileHoldIngestLimits.hardMaximumInputCount + 1
            invalidLimits.append(candidate)
            candidate = FileHoldIngestLimits()
            candidate.maximumItemCount = FileHoldIngestLimits.hardMaximumItemCount + 1
            invalidLimits.append(candidate)
            candidate = FileHoldIngestLimits()
            candidate.maximumItemBytes = FileHoldIngestLimits.hardMaximumItemBytes + 1
            invalidLimits.append(candidate)
            candidate = FileHoldIngestLimits()
            candidate.maximumTotalBytes = FileHoldIngestLimits.hardMaximumTotalBytes + 1
            invalidLimits.append(candidate)
            candidate = FileHoldIngestLimits()
            candidate.maximumPathBytes = FileHoldIngestLimits.hardMaximumPathBytes + 1
            invalidLimits.append(candidate)
            candidate = FileHoldIngestLimits()
            candidate.maximumBookmarkBytes = FileHoldIngestLimits.hardMaximumBookmarkBytes + 1
            invalidLimits.append(candidate)
            candidate = FileHoldIngestLimits()
            candidate.maximumExpiryInterval = FileHoldIngestLimits.hardMaximumExpiryInterval + 1
            invalidLimits.append(candidate)
            candidate = FileHoldIngestLimits()
            candidate.maximumTerminalHistoryCount = FileHoldIngestLimits.hardMaximumTerminalHistoryCount + 1
            invalidLimits.append(candidate)
            for (index, limits) in invalidLimits.enumerated() {
                do {
                    _ = try makeStore(
                        root: sandbox.appendingPathComponent("invalid-\(index)"),
                        limits: limits,
                        idPrefix: "invalid"
                    )
                    recordFailure("hard limit \(index) accepted an upper-bound bypass")
                } catch FileHoldError.invalidConfiguration {
                    check(true, "hard limit \(index) rejects an upper-bound bypass")
                }
            }

            let source = sandbox.appendingPathComponent("source")
            try Data("expiry".utf8).write(to: source)
            let unmarkedRoot = sandbox.appendingPathComponent("unmarked-root")
            try FileManager.default.createDirectory(
                at: unmarkedRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            do {
                _ = try makeStore(root: unmarkedRoot, idPrefix: "unmarked")
                recordFailure("unmarked existing root was accepted")
            } catch FileHoldError.unsafeStorage {
                check(true, "existing root requires Erylo ownership marker")
            }

            let invariantRoot = sandbox.appendingPathComponent("invariant-root")
            let invariantStore = try makeStore(root: invariantRoot, idPrefix: "invariant")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: invariantRoot.path
            )
            check(
                failure(
                    of: await invariantStore.ingest([source], options: .init(mode: .temporaryCopy)),
                    at: 0
                ) == .unsafeStorage,
                "root uid/mode/marker invariant is rechecked before filesystem use"
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: invariantRoot.path
            )
            let expiryStore = try makeStore(root: sandbox.appendingPathComponent("expiry-root"), idPrefix: "expiry-bound")
            check(
                failure(
                    of: await expiryStore.ingest(
                        [source],
                        options: .init(mode: .temporaryCopy, expiresAt: .distantFuture)
                    ),
                    at: 0
                ) == .invalidExpiry,
                "distant future expiry is rejected by the store bound"
            )
            let nanDate = Date(timeIntervalSinceReferenceDate: .nan)
            check(
                failure(
                    of: await expiryStore.ingest(
                        [source],
                        options: .init(mode: .temporaryCopy, expiresAt: nanDate)
                    ),
                    at: 0
                ) == .invalidExpiry,
                "NaN expiry is rejected"
            )
            do {
                try await OneShotFileHoldExpiryScheduler().sleep(until: .distantFuture)
                recordFailure("public scheduler accepted distantFuture")
            } catch FileHoldError.invalidExpiry {
                check(true, "public scheduler rejects distantFuture without numeric conversion traps")
            }

            let clock = MutableClock(fixedNow)
            let expiryObserver = GatedCopyObserver()
            let duringCopyRoot = sandbox.appendingPathComponent("expires-during-copy")
            let duringCopyStore = try makeStore(
                root: duringCopyRoot,
                copyObserver: expiryObserver,
                clock: { clock.now() },
                idPrefix: "expires-during-copy"
            )
            let deadline = fixedNow.addingTimeInterval(10)
            let duringCopyTask = Task {
                await duringCopyStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy, expiresAt: deadline)
                )
            }
            await expiryObserver.waitUntilReached()
            clock.set(deadline)
            await expiryObserver.release()
            check(
                failure(of: await duringCopyTask.value, at: 0) == .invalidExpiry,
                "expiry passing during copy prevents publication/commit"
            )
            check(try directoryNames(duringCopyRoot).isEmpty, "expired in-flight copy is identity-safely removed")

            let schedulerFailureRoot = sandbox.appendingPathComponent("scheduler-failure-root")
            let schedulerFailureStore = try makeStore(
                root: schedulerFailureRoot,
                scheduler: ThrowingExpiryScheduler(),
                idPrefix: "scheduler-failure"
            )
            let schedulerFailureItem = try requireHeld(
                await schedulerFailureStore.ingest(
                    [source],
                    options: .init(mode: .temporaryCopy, expiresAt: fixedNow.addingTimeInterval(60))
                ),
                at: 0
            )
            check(
                await waitForStatus(
                    schedulerFailureStore,
                    itemID: schedulerFailureItem.id,
                    expected: .attentionRequired(error: .expirySchedulerFailed, at: fixedNow)
                ),
                "scheduler failure becomes explicit retained attention state"
            )
            let retainedURL = schedulerFailureRoot.appendingPathComponent(relativeName(of: schedulerFailureItem))
            check(FileManager.default.fileExists(atPath: retainedURL.path), "scheduler failure never deletes before deadline")
            let retainedData: Data = try await schedulerFailureStore.withAccessibleURL(for: schedulerFailureItem.id) {
                try Data(contentsOf: $0)
            }
            check(retainedData == Data("expiry".utf8), "attention state remains available for manual save")
            _ = await schedulerFailureStore.remove(schedulerFailureItem.id)

            let historyStore = try makeStore(
                root: sandbox.appendingPathComponent("history-root"),
                limits: FileHoldIngestLimits(maximumTerminalHistoryCount: 3),
                idPrefix: "history"
            )
            for _ in 0..<40 {
                let item = try requireHeld(
                    await historyStore.ingest(
                        [source],
                        options: .init(mode: .reference, duplicatePolicy: .allow)
                    ),
                    at: 0
                )
                _ = await historyStore.remove(item.id)
            }
            check((await historyStore.items()).count <= 3, "terminal records remain strictly history bounded")

            let ignoringScheduler = IgnoringCancellationExpiryScheduler()
            let constantID = HeldFileID(rawValue: "reused-id")
            let nonceStore = try makeStore(
                root: sandbox.appendingPathComponent("nonce-root"),
                limits: FileHoldIngestLimits(maximumTerminalHistoryCount: 0),
                scheduler: ignoringScheduler,
                makeID: { constantID },
                idPrefix: "unused"
            )
            let sharedDeadline = fixedNow.addingTimeInterval(30)
            let first = try requireHeld(
                await nonceStore.ingest([source], options: .init(mode: .reference, expiresAt: sharedDeadline)),
                at: 0
            )
            check(await waitForPending(ignoringScheduler, count: 1), "stale nonce test installs first scheduler")
            _ = await nonceStore.remove(first.id)
            let reused = try requireHeld(
                await nonceStore.ingest([source], options: .init(mode: .reference, expiresAt: sharedDeadline)),
                at: 0
            )
            check(await waitForPending(ignoringScheduler, count: 2), "constant ID is reused only after terminal pruning")
            await ignoringScheduler.fire(at: 0)
            await yieldSeveralTimes()
            check(await nonceStore.item(id: reused.id)?.status == .available, "old scheduler cannot expire a reused ID")
            await ignoringScheduler.fire(at: 1)
            await yieldSeveralTimes()
            check(await nonceStore.item(id: reused.id) == nil, "current nonce expiry completes and prunes zero-history record")

            let shutdownObserver = GatedCopyObserver()
            let shutdownRoot = sandbox.appendingPathComponent("shutdown-root")
            let shutdownStore = try makeStore(
                root: shutdownRoot,
                copyObserver: shutdownObserver,
                idPrefix: "shutdown"
            )
            let shutdownIngest = Task {
                await shutdownStore.ingest([source], options: .init(mode: .temporaryCopy))
            }
            await shutdownObserver.waitUntilReached()
            let shutdownTask = Task { try await shutdownStore.shutdown() }
            await yieldSeveralTimes()
            await shutdownObserver.release()
            let shutdownReport = try await shutdownTask.value
            check(
                failure(of: await shutdownIngest.value, at: 0) == .storeShutDown,
                "shutdown cancels and drains an in-flight reservation"
            )
            check(shutdownReport.cleanupResults.isEmpty, "uncommitted shutdown copy is cleaned before report")
            check(try directoryNames(shutdownRoot).isEmpty, "awaited shutdown leaves no copy or stage")
            check((await shutdownStore.items()).isEmpty, "shutdown race cannot commit after drain")
        } catch {
            recordUnexpected(error, test: "expiry limits/shutdown/history")
        }
    }

    mutating func verifyReferenceRevalidation() async {
        guard let sandbox = try? makeSandbox("reference-revalidation") else {
            recordFailure("reference revalidation setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let source = sandbox.appendingPathComponent("reference-source")
            try Data("four".utf8).write(to: source)

            let oversizedTracker = ReferenceTracker(oversizedBookmarkNames: [source.lastPathComponent])
            let oversizedStore = try makeStore(
                root: sandbox.appendingPathComponent("oversized-bookmark-root"),
                codec: TestReferenceCodec(tracker: oversizedTracker),
                idPrefix: "oversized-bookmark"
            )
            check(
                failure(of: await oversizedStore.ingest([source], options: .init(mode: .reference)), at: 0)
                    == .bookmarkTooLarge(maximumBytes: 64 * 1_024),
                "bookmark bytes are bounded after codec creation"
            )

            let mutationTracker = ReferenceTracker(afterBookmark: { url in
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data([0x21]))
                    try? handle.close()
                }
            })
            let mutationStore = try makeStore(
                root: sandbox.appendingPathComponent("bookmark-mutation-root"),
                codec: TestReferenceCodec(tracker: mutationTracker),
                idPrefix: "bookmark-mutation"
            )
            check(
                failure(of: await mutationStore.ingest([source], options: .init(mode: .reference)), at: 0)
                    == .sourceChangedDuringCopy,
                "reference source is re-inspected after bookmark creation"
            )
            try Data("four".utf8).write(to: source, options: .atomic)

            for (label, expectedError) in [
                ("stale", FileHoldError.staleBookmark),
                ("resolution", FileHoldError.bookmarkResolutionFailed),
            ] {
                let tracker = ReferenceTracker(resolutionErrors: [source.lastPathComponent: expectedError])
                let store = try makeStore(
                    root: sandbox.appendingPathComponent("\(label)-root"),
                    codec: TestReferenceCodec(tracker: tracker),
                    idPrefix: label
                )
                let item = try requireHeld(
                    await store.ingest([source], options: .init(mode: .reference)),
                    at: 0
                )
                do {
                    let _: URL = try await store.withAccessibleURL(for: item.id) { $0 }
                    recordFailure("\(label) bookmark unexpectedly presented")
                } catch let error as FileHoldError {
                    check(error == expectedError, "\(label) bookmark error is preserved")
                }
            }

            let substitute = sandbox.appendingPathComponent("substitute")
            try Data("four".utf8).write(to: substitute)
            let substitutionTracker = ReferenceTracker(
                resolvedURLOverrides: [source.lastPathComponent: substitute]
            )
            let substitutionStore = try makeStore(
                root: sandbox.appendingPathComponent("substitution-root"),
                codec: TestReferenceCodec(tracker: substitutionTracker),
                idPrefix: "substitution"
            )
            let substitutionItem = try requireHeld(
                await substitutionStore.ingest([source], options: .init(mode: .reference)),
                at: 0
            )
            do {
                let _: URL = try await substitutionStore.withAccessibleURL(for: substitutionItem.id) { $0 }
                recordFailure("substituted reference target unexpectedly presented")
            } catch FileHoldError.referenceTargetChanged {
                check(substitutionTracker.stops == 1, "target substitution releases started security scope")
            }

            let nonFileTracker = ReferenceTracker(
                resolvedURLOverrides: [source.lastPathComponent: URL(string: "https://example.com/file")!]
            )
            let nonFileStore = try makeStore(
                root: sandbox.appendingPathComponent("non-file-reference-root"),
                codec: TestReferenceCodec(tracker: nonFileTracker),
                idPrefix: "non-file-reference"
            )
            let nonFileItem = try requireHeld(
                await nonFileStore.ingest([source], options: .init(mode: .reference)),
                at: 0
            )
            do {
                let _: URL = try await nonFileStore.withAccessibleURL(for: nonFileItem.id) { $0 }
                recordFailure("non-file resolved target unexpectedly presented")
            } catch FileHoldError.notFileURL {
                check(nonFileTracker.stops == 1, "non-file target failure releases security scope")
            }

            let directory = sandbox.appendingPathComponent("resolved-directory", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let directoryTracker = ReferenceTracker(
                resolvedURLOverrides: [source.lastPathComponent: directory]
            )
            let directoryStore = try makeStore(
                root: sandbox.appendingPathComponent("directory-reference-root"),
                codec: TestReferenceCodec(tracker: directoryTracker),
                idPrefix: "directory-reference"
            )
            let directoryItem = try requireHeld(
                await directoryStore.ingest([source], options: .init(mode: .reference)),
                at: 0
            )
            do {
                let _: URL = try await directoryStore.withAccessibleURL(for: directoryItem.id) { $0 }
                recordFailure("directory resolved target unexpectedly presented")
            } catch FileHoldError.sourceIsNotRegularFile {
                check(directoryTracker.stops == 1, "directory target failure releases security scope")
            }

            let liveTracker = ReferenceTracker()
            let liveStore = try makeStore(
                root: sandbox.appendingPathComponent("live-reference-root"),
                limits: FileHoldIngestLimits(maximumItemBytes: 16, maximumTotalBytes: 16),
                codec: TestReferenceCodec(tracker: liveTracker),
                idPrefix: "live-reference"
            )
            let liveItem = try requireHeld(
                await liveStore.ingest([source], options: .init(mode: .reference)),
                at: 0
            )
            try Data("grown-value".utf8).write(to: source)
            let grown: Data = try await liveStore.withAccessibleURL(for: liveItem.id) {
                try Data(contentsOf: $0)
            }
            check(grown == Data("grown-value".utf8), "live reference permits same-identity growth within limits")
            check(await liveStore.item(id: liveItem.id)?.source.byteCount == 11, "live reference refreshes grown metadata")
            try Data("x".utf8).write(to: source)
            _ = try await liveStore.withAccessibleURL(for: liveItem.id) { $0 }
            check(await liveStore.item(id: liveItem.id)?.source.byteCount == 1, "live reference refreshes shrunk metadata")
            try Data(repeating: 0x41, count: 17).write(to: source)
            do {
                let _: URL = try await liveStore.withAccessibleURL(for: liveItem.id) { $0 }
                recordFailure("oversized live reference unexpectedly presented")
            } catch FileHoldError.itemTooLarge(maximumBytes: 16, actualBytes: 17) {
                check(liveTracker.activeAccesses == 0, "oversized live target releases scope")
            }

            let reservedReference = sandbox.appendingPathComponent("reserved-reference")
            let reservedCopy = sandbox.appendingPathComponent("reserved-copy")
            try Data(repeating: 0x52, count: 4).write(to: reservedReference)
            try Data(repeating: 0x43, count: 8).write(to: reservedCopy)
            let reservationObserver = GatedCopyObserver()
            let reservationTracker = ReferenceTracker()
            let reservationStore = try makeStore(
                root: sandbox.appendingPathComponent("reference-reservation-root"),
                limits: FileHoldIngestLimits(
                    maximumItemCount: 2,
                    maximumItemBytes: 12,
                    maximumTotalBytes: 12
                ),
                codec: TestReferenceCodec(tracker: reservationTracker),
                copyObserver: reservationObserver,
                idPrefix: "reference-reservation"
            )
            let reservedReferenceItem = try requireHeld(
                await reservationStore.ingest([reservedReference], options: .init(mode: .reference)),
                at: 0
            )
            let reservedCopyTask = Task {
                await reservationStore.ingest([reservedCopy], options: .init(mode: .temporaryCopy))
            }
            await reservationObserver.waitUntilReached()
            try Data(repeating: 0x53, count: 5).write(to: reservedReference)
            do {
                let _: URL = try await reservationStore.withAccessibleURL(
                    for: reservedReferenceItem.id
                ) { $0 }
                recordFailure("reference growth ignored reserved copy bytes")
            } catch FileHoldError.totalSizeExceeded(maximumBytes: 12) {
                check(
                    reservationTracker.activeAccesses == 0,
                    "growth rejection with reservation releases reference scope"
                )
            }
            await reservationObserver.release()
            check((await reservedCopyTask.value).heldItems.count == 1, "reserved copy commits after rejected growth")
        } catch {
            recordUnexpected(error, test: "reference revalidation")
        }
    }

    mutating func verifyPublicDragRepresentationCap() async {
        guard let sandbox = try? makeSandbox("drag") else {
            recordFailure("drag setup failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let first = sandbox.appendingPathComponent("first")
            let third = sandbox.appendingPathComponent("third")
            try Data().write(to: first)
            try Data().write(to: third)
            let tracker = DragLoadTracker()
            let report = await decodeDropForTest(firstURL: first, thirdURL: third, tracker: tracker)
            check(report.entries.map(\.providerIndex) == [0, 1], "drag decoder keeps provider order")
            check(report.fileURLs == [first], "drag decoder returns valid public file URLs only")
            check(
                report.entries[1].outcome == .failure(.invalidDragRepresentation),
                "invalid public drag data is reported partially"
            )
            check(report.unprocessedProviderCount == 1, "drag decoder reports providers beyond cap")
            check(tracker.loadCount == 2, "drag decoder never loads providers beyond cap")
            check(tracker.cancellationCount == 0, "synchronous successful callbacks do not cancel late Progress")
            check(
                (await decodeUnsupportedDropForTest()).entries.first?.outcome
                    == .failure(.unsupportedDragRepresentation),
                "unsupported public drag representation is rejected"
            )

            let clampedLimits = await clampedDropLimitsForTest()
            check(
                clampedLimits.providers == PublicFileURLDropDecoder.hardMaximumProviderCount,
                "configurable provider cap clamps to a hard ceiling"
            )
            check(
                clampedLimits.bytes == PublicFileURLDropDecoder.hardMaximumRepresentationBytes,
                "configurable representation cap clamps to a hard ceiling"
            )

            let oversizedScheduler = ManualDropTimeoutScheduler()
            let oversizedTracker = DragLoadTracker()
            let oversizedController = DeferredDragProviderController()
            let oversizedTask = Task {
                await decodeDeferredDropForTest(
                    scheduler: oversizedScheduler,
                    tracker: oversizedTracker,
                    controller: oversizedController,
                    maximumRepresentationBytes: 8
                )
            }
            check(
                await waitForDeferredProvider(oversizedController),
                "oversized provider waits until Progress is installed"
            )
            oversizedController.complete(with: Data(repeating: 0x41, count: 9))
            let oversized = await oversizedTask.value
            check(
                oversized.entries.first?.outcome
                    == .failure(.dragRepresentationTooLarge(maximumBytes: 8)),
                "oversized drag representation is rejected before URL decoding"
            )
            check(
                await waitForDragCancellation(oversizedTracker, count: 1),
                "oversized representation deterministically cancels installed provider progress"
            )

            let coordinatedRepresentation = sandbox.appendingPathComponent("coordinated-representation")
            try first.dataRepresentation.write(to: coordinatedRepresentation)
            let coordinationProbe = DropFileCoordinatorProbe(
                suppliedURL: coordinatedRepresentation,
                removeAfterAccess: true
            )
            let coordinatedReport = await decodeDropWithCoordinatorForTest(
                providerData: Data("not the coordinated value".utf8),
                tracker: DragLoadTracker(),
                coordinator: coordinationProbe
            )
            check(coordinationProbe.callCount == 1, "every provider URL enters the coordination seam")
            check(
                coordinatedReport.fileURLs == [first],
                "bounded decode uses only the coordinator-supplied URL"
            )
            check(
                !FileManager.default.fileExists(atPath: coordinatedRepresentation.path),
                "descriptor decode finishes before the coordination accessor returns"
            )
            let failingCoordinator = DropFileCoordinatorProbe(shouldFail: true)
            let failedCoordination = await decodeDropWithCoordinatorForTest(
                providerData: first.dataRepresentation,
                tracker: DragLoadTracker(),
                coordinator: failingCoordinator
            )
            check(
                failedCoordination.entries.first?.outcome == .failure(.invalidDragRepresentation),
                "coordination failures map to invalid drag representations"
            )

            let timeoutScheduler = ManualDropTimeoutScheduler()
            let timeoutTracker = DragLoadTracker()
            let timeoutController = DeferredDragProviderController()
            let timeoutTask = Task {
                await decodeDeferredDropForTest(
                    scheduler: timeoutScheduler,
                    tracker: timeoutTracker,
                    controller: timeoutController
                )
            }
            check(await waitForDropTimeout(timeoutScheduler), "timeout seam receives one one-shot wait")
            check(await waitForDeferredProvider(timeoutController), "deferred provider installs completion")
            await timeoutScheduler.fire()
            let timedOut = await timeoutTask.value
            check(
                timedOut.entries.first?.outcome == .failure(.dragRepresentationTimedOut),
                "provider that never completes terminates at injected timeout"
            )
            check(
                await waitForDragCancellation(timeoutTracker, count: 1),
                "timeout cancels provider progress"
            )
            timeoutController.complete(with: first.dataRepresentation)
            timeoutController.complete(with: first.dataRepresentation)
            await yieldSeveralTimes()
            check(
                timedOut.entries.first?.outcome == .failure(.dragRepresentationTimedOut),
                "late or duplicate completion cannot resume timeout twice"
            )

            let cancellationScheduler = ManualDropTimeoutScheduler()
            let cancellationTracker = DragLoadTracker()
            let cancellationController = DeferredDragProviderController()
            let cancellationTask = Task {
                await decodeDeferredDropForTest(
                    scheduler: cancellationScheduler,
                    tracker: cancellationTracker,
                    controller: cancellationController
                )
            }
            check(await waitForDropTimeout(cancellationScheduler), "cancellation case starts timeout task")
            check(await waitForDeferredProvider(cancellationController), "cancellation case starts provider")
            cancellationTask.cancel()
            let cancelled = await cancellationTask.value
            check(cancelled.entries.first?.outcome == .failure(.cancelled), "caller cancellation resumes provider load")
            check(
                await waitForDragCancellation(cancellationTracker, count: 1),
                "caller cancellation cancels provider progress"
            )
            cancellationController.complete(with: first.dataRepresentation)
            await yieldSeveralTimes()

            let preCancelledTracker = DragLoadTracker()
            let preCancelled = await decodePreCancelledDropForTest(tracker: preCancelledTracker)
            check(
                preCancelled.entries.first?.outcome == .failure(.cancelled),
                "pre-install cancellation reports cancellation"
            )
            check(preCancelledTracker.loadCount == 0, "pre-install cancellation performs zero provider work")

            let throwingTracker = DragLoadTracker()
            let throwingController = DeferredDragProviderController()
            let throwingTimeout = await decodeThrowingTimeoutForTest(
                tracker: throwingTracker,
                controller: throwingController
            )
            check(
                throwingTimeout.entries.first?.outcome
                    == .failure(.dragTimeoutSchedulingFailed),
                "throwing timeout scheduler resumes exactly once with explicit failure"
            )
            check(
                await waitForDragCancellation(throwingTracker, count: 1),
                "timeout scheduler failure cancels provider progress"
            )
        } catch {
            recordUnexpected(error, test: "public drag cap")
        }
    }

    private func makeStore(
        root: URL,
        limits: FileHoldIngestLimits = FileHoldIngestLimits(),
        codec: any FileReferenceCoding = TestReferenceCodec(tracker: ReferenceTracker()),
        scheduler: any FileHoldExpiryScheduling = OneShotFileHoldExpiryScheduler(),
        copyObserver: any FileHoldCopyObserving = DisabledFileHoldCopyObserver(),
        storageObserver: any FileHoldStorageObserving = DisabledFileHoldStorageObserver(),
        clock: (@Sendable () -> Date)? = nil,
        makeID customMakeID: (@Sendable () -> HeldFileID)? = nil,
        idPrefix: String
    ) throws -> FileHoldStore {
        let sequence = IDSequence(prefix: idPrefix)
        let defaultNow = fixedNow
        return try FileHoldStore(
            rootURL: root,
            limits: limits,
            referenceCodec: codec,
            expiryScheduler: scheduler,
            copyObserver: copyObserver,
            storageObserver: storageObserver,
            now: clock ?? { defaultNow },
            makeID: customMakeID ?? { sequence.next() }
        )
    }

    private mutating func check(_ condition: Bool, _ name: String) {
        checkCount += 1
        if !condition { failures.append(name) }
    }

    private mutating func recordFailure(_ name: String) {
        checkCount += 1
        failures.append(name)
    }

    private mutating func recordUnexpected(_ error: Error, test: String) {
        recordFailure("\(test) threw unexpected error: \(error)")
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("File Hold harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        fputs("File Hold harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private enum ProbeError: Error {
    case expected
    case unexpectedResources
}
