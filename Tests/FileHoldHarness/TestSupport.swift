import EryloFileHold
import Foundation
import UniformTypeIdentifiers

final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var value = 0

    init(prefix: String) {
        self.prefix = prefix
    }

    func next() -> HeldFileID {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return HeldFileID(rawValue: "\(prefix)-\(value)")
    }
}

final class ConstantIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private let id: HeldFileID
    private var callValue = 0

    init(_ rawValue: String) {
        id = HeldFileID(rawValue: rawValue)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callValue
    }

    func next() -> HeldFileID {
        lock.lock()
        callValue += 1
        lock.unlock()
        return id
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

actor GatedCopyObserver: FileHoldCopyObserving {
    private var didGate = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func didCopy(byteCount _: Int64) async {
        guard !didGate else { return }
        didGate = true
        for waiter in reachedWaiters { waiter.resume() }
        reachedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilReached() async {
        if didGate { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class ReferenceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let bookmarkFailureNames: Set<String>
    private let deniedAccessNames: Set<String>
    private let oversizedBookmarkNames: Set<String>
    private let resolutionErrors: [String: FileHoldError]
    private let resolvedURLOverrides: [String: URL]
    private let afterBookmark: (@Sendable (URL) -> Void)?
    private var startValue = 0
    private var stopValue = 0
    private var activeValue = 0

    init(
        bookmarkFailureNames: Set<String> = [],
        deniedAccessNames: Set<String> = [],
        oversizedBookmarkNames: Set<String> = [],
        resolutionErrors: [String: FileHoldError] = [:],
        resolvedURLOverrides: [String: URL] = [:],
        afterBookmark: (@Sendable (URL) -> Void)? = nil
    ) {
        self.bookmarkFailureNames = bookmarkFailureNames
        self.deniedAccessNames = deniedAccessNames
        self.oversizedBookmarkNames = oversizedBookmarkNames
        self.resolutionErrors = resolutionErrors
        self.resolvedURLOverrides = resolvedURLOverrides
        self.afterBookmark = afterBookmark
    }

    var successfulStarts: Int {
        lock.lock()
        defer { lock.unlock() }
        return startValue
    }

    var stops: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopValue
    }

    var activeAccesses: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeValue
    }

    func shouldFailBookmark(for url: URL) -> Bool {
        bookmarkFailureNames.contains(url.lastPathComponent)
    }

    func bookmark(for url: URL) -> Data {
        let data = oversizedBookmarkNames.contains(url.lastPathComponent)
            ? Data(repeating: 0x41, count: FileHoldIngestLimits.hardMaximumBookmarkBytes + 1)
            : url.dataRepresentation
        afterBookmark?(url)
        return data
    }

    func resolution(for url: URL) throws -> URL {
        if let error = resolutionErrors[url.lastPathComponent] { throw error }
        return resolvedURLOverrides[url.lastPathComponent] ?? url
    }

    func start(_ url: URL) -> Bool {
        guard !deniedAccessNames.contains(url.lastPathComponent) else { return false }
        lock.lock()
        startValue += 1
        activeValue += 1
        lock.unlock()
        return true
    }

    func stop() {
        lock.lock()
        stopValue += 1
        activeValue -= 1
        lock.unlock()
    }
}

struct TestReferenceCodec: FileReferenceCoding {
    let tracker: ReferenceTracker

    func makeBookmark(for url: URL) throws -> Data {
        guard !tracker.shouldFailBookmark(for: url) else {
            throw FileHoldError.bookmarkCreationFailed
        }
        return tracker.bookmark(for: url)
    }

    func resolveBookmark(_ bookmark: Data) throws -> ResolvedFileReference {
        guard let url = URL(dataRepresentation: bookmark, relativeTo: nil) else {
            throw FileHoldError.bookmarkResolutionFailed
        }
        let resolvedURL = try tracker.resolution(for: url)
        return ResolvedFileReference(
            url: resolvedURL,
            startAccess: { tracker.start(resolvedURL) },
            stopAccess: { tracker.stop() }
        )
    }
}

actor IgnoringCancellationExpiryScheduler: FileHoldExpiryScheduling {
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    func sleep(until _: Date) async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func pendingCount() -> Int { continuations.count }

    func fire(at index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].resume()
    }
}

struct ThrowingExpiryScheduler: FileHoldExpiryScheduling {
    func sleep(until _: Date) async throws {
        throw ProbeSchedulerError.failed
    }
}

struct ThrowingDropTimeoutScheduler: FileHoldDropTimeoutScheduling {
    func waitForTimeout() async throws {
        throw ProbeSchedulerError.failed
    }
}

private enum ProbeSchedulerError: Error {
    case failed
}

actor PublishGateObserver: FileHoldCopyObserving {
    private var publishedName: String?
    private var reachedWaiters: [CheckedContinuation<String, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func didPublishCandidate(relativeName: String) async {
        publishedName = relativeName
        for waiter in reachedWaiters { waiter.resume(returning: relativeName) }
        reachedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPublished() async -> String {
        if let publishedName { return publishedName }
        return await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class QuarantineCollisionObserver: FileHoldStorageObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var fired = false

    init(root: URL) {
        self.root = root
    }

    func didQuarantineEntry(relativeName _: String, originalName: String) {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        _ = FileManager.default.createFile(
            atPath: root.appendingPathComponent(originalName).path,
            contents: Data("restore blocker".utf8)
        )
    }
}

final class MovedQuarantineCollisionObserver: FileHoldStorageObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    let movedRelativeName: String
    private var fired = false
    private var moveSucceededValue = false

    init(root: URL, movedRelativeName: String) {
        self.root = root
        self.movedRelativeName = movedRelativeName
    }

    var moveSucceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return moveSucceededValue
    }

    func didQuarantineEntry(relativeName: String, originalName: String) {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()

        let quarantineURL = root.appendingPathComponent(relativeName)
        let movedURL = root.appendingPathComponent(movedRelativeName)
        let moved = (try? FileManager.default.moveItem(at: quarantineURL, to: movedURL)) != nil
        if moved {
            _ = FileManager.default.createFile(
                atPath: root.appendingPathComponent(originalName).path,
                contents: Data("restore blocker".utf8)
            )
        }

        lock.lock()
        moveSucceededValue = moved
        lock.unlock()
    }
}

final class MoveAndReplaceQuarantineObserver: FileHoldStorageObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    let movedRelativeName: String
    let replacementData: Data
    private var fired = false
    private var mutationSucceededValue = false

    init(root: URL, movedRelativeName: String, replacementData: Data) {
        self.root = root
        self.movedRelativeName = movedRelativeName
        self.replacementData = replacementData
    }

    var mutationSucceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutationSucceededValue
    }

    func didQuarantineEntry(relativeName: String, originalName: String) {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()

        let quarantineURL = root.appendingPathComponent(relativeName)
        let movedURL = root.appendingPathComponent(movedRelativeName)
        let moved = (try? FileManager.default.moveItem(at: quarantineURL, to: movedURL)) != nil
        let replaced = moved && FileManager.default.createFile(
            atPath: quarantineURL.path,
            contents: replacementData
        )
        let blocked = replaced && FileManager.default.createFile(
            atPath: root.appendingPathComponent(originalName).path,
            contents: Data("restore blocker".utf8)
        )

        lock.lock()
        mutationSucceededValue = moved && replaced && blocked
        lock.unlock()
    }
}

actor ManualExpiryScheduler: FileHoldExpiryScheduling {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [UUID: Waiter] = [:]
    private var cancellationValue = 0

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance(to date: Date) {
        let readyIDs = waiters.compactMap { id, waiter in
            waiter.deadline <= date ? id : nil
        }
        for id in readyIDs {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func pendingCount() -> Int { waiters.count }
    func cancellationCount() -> Int { cancellationValue }

    private func cancel(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            cancellationValue += 1
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}

actor ManualDropTimeoutScheduler: FileHoldDropTimeoutScheduling {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var waitValue = 0
    private var cancellationValue = 0

    func waitForTimeout() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waitValue += 1
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }

    func waitCount() -> Int { waitValue }
    func cancellationCount() -> Int { cancellationValue }

    private func cancel() {
        if let continuation {
            cancellationValue += 1
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}

actor LeaseGate {
    private var enteredURL: URL?
    private var enteredWaiters: [CheckedContinuation<URL, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func enter(url: URL) async {
        enteredURL = url
        for waiter in enteredWaiters { waiter.resume(returning: url) }
        enteredWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async -> URL {
        if let enteredURL { return enteredURL }
        return await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class HardDeadlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ value: Bool) {
        let continuationToResume: CheckedContinuation<Bool, Never>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(returning: value)
    }
}

func valueBeforeHardDeadline(
    nanoseconds: UInt64 = 2_000_000_000,
    operation: @escaping @Sendable () async -> Bool
) async -> Bool {
    let state = HardDeadlineState()
    return await withCheckedContinuation { continuation in
        state.install(continuation)
        Task {
            state.finish(await operation())
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .nanoseconds(Int(nanoseconds))
        ) {
            state.finish(false)
        }
    }
}

final class DragLoadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var cancellationValue = 0

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationValue
    }

    func loaded() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func cancelled() {
        lock.lock()
        cancellationValue += 1
        lock.unlock()
    }
}

final class DeferredDragProviderController: FileHoldDropLoadObserving, @unchecked Sendable {
    typealias Completion = (Data?, (any Error)?) -> Void

    private let lock = NSLock()
    private var completion: Completion?
    private var progressInstalled = false

    func install(_ completion: @escaping Completion) {
        lock.lock()
        self.completion = completion
        lock.unlock()
    }

    func complete(with data: Data) {
        lock.lock()
        let completion = completion
        lock.unlock()
        completion?(data, nil)
    }

    func didInstallProviderProgress() {
        lock.lock()
        progressInstalled = true
        lock.unlock()
    }

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    var isProgressInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return progressInstalled
    }
}

final class DropFileCoordinatorProbe: FileHoldDropFileCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private let suppliedURL: URL?
    private let shouldFail: Bool
    private let removeAfterAccess: Bool
    private var callValue = 0

    init(
        suppliedURL: URL? = nil,
        shouldFail: Bool = false,
        removeAfterAccess: Bool = false
    ) {
        self.suppliedURL = suppliedURL
        self.shouldFail = shouldFail
        self.removeAfterAccess = removeAfterAccess
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callValue
    }

    func coordinateReadingFileURL(
        _ representationURL: URL,
        accessor: @escaping @Sendable (URL) -> Result<URL, FileHoldError>
    ) throws -> Result<URL, FileHoldError> {
        lock.lock()
        callValue += 1
        lock.unlock()
        guard !shouldFail else { throw ProbeCoordinatorError.failed }
        let coordinatedURL = suppliedURL ?? representationURL
        let result = accessor(coordinatedURL)
        if removeAfterAccess {
            try? FileManager.default.removeItem(at: coordinatedURL)
        }
        return result
    }
}

private enum ProbeCoordinatorError: Error {
    case failed
}

@MainActor
func decodeDropForTest(
    firstURL: URL,
    thirdURL: URL,
    tracker: DragLoadTracker
) async -> FileHoldDropReport {
    let first = dragProvider(data: firstURL.dataRepresentation, tracker: tracker)
    let invalid = dragProvider(data: Data("https://example.com".utf8), tracker: tracker)
    let beyondCap = dragProvider(data: thirdURL.dataRepresentation, tracker: tracker)
    return await PublicFileURLDropDecoder(maximumProviderCount: 2).decode([
        first,
        invalid,
        beyondCap,
    ])
}

@MainActor
func decodeUnsupportedDropForTest() async -> FileHoldDropReport {
    await PublicFileURLDropDecoder().decode([NSItemProvider()])
}

@MainActor
func decodeDeferredDropForTest(
    scheduler: ManualDropTimeoutScheduler,
    tracker: DragLoadTracker,
    controller: DeferredDragProviderController,
    maximumRepresentationBytes: Int = 128
) async -> FileHoldDropReport {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.fileURL.identifier,
        visibility: .all
    ) { completion in
        tracker.loaded()
        controller.install(completion)
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = { tracker.cancelled() }
        return progress
    }
    return await PublicFileURLDropDecoder(
        maximumRepresentationBytes: maximumRepresentationBytes,
        timeoutScheduler: scheduler,
        loadObserver: controller
    ).decode([provider])
}

@MainActor
func decodeDropWithCoordinatorForTest(
    providerData: Data,
    tracker: DragLoadTracker,
    coordinator: DropFileCoordinatorProbe
) async -> FileHoldDropReport {
    await PublicFileURLDropDecoder(fileCoordinator: coordinator).decode([
        dragProvider(data: providerData, tracker: tracker),
    ])
}

@MainActor
func clampedDropLimitsForTest() -> (providers: Int, bytes: Int) {
    let decoder = PublicFileURLDropDecoder(
        maximumProviderCount: Int.max,
        maximumRepresentationBytes: Int.max
    )
    return (decoder.maximumProviderCount, decoder.maximumRepresentationBytes)
}

@MainActor
private func dragProvider(data: Data, tracker: DragLoadTracker) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.fileURL.identifier,
        visibility: .all
    ) { completion in
        tracker.loaded()
        completion(data, nil)
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = { tracker.cancelled() }
        return progress
    }
    return provider
}

func makeSandbox(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("erylo-file-hold-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func createSparseFile(at url: URL, byteCount: UInt64) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: byteCount)
    try handle.close()
}

func createUntrustedDirectoryTree(
    at url: URL,
    payloadByteCount: UInt64,
    externalLinkTarget: URL
) throws {
    let nestedDirectory = url.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(
        at: nestedDirectory,
        withIntermediateDirectories: true
    )
    try createSparseFile(
        at: nestedDirectory.appendingPathComponent("payload.bin"),
        byteCount: payloadByteCount
    )
    try FileManager.default.createSymbolicLink(
        at: url.appendingPathComponent("outside-link"),
        withDestinationURL: externalLinkTarget
    )
}

func untrustedTreePayload(at url: URL) -> URL {
    url.appendingPathComponent("nested/payload.bin")
}

func fileSize(_ url: URL) throws -> UInt64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return UInt64(values.fileSize ?? -1)
}

func directoryNames(_ url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path)
        .filter { $0 != ".erylo-file-hold-root" }
        .sorted()
}

func requireHeld(
    _ report: FileHoldIngestReport,
    at inputIndex: Int
) throws -> HeldFileItem {
    guard let entry = report.entries.first(where: { $0.inputIndex == inputIndex }) else {
        throw FileHoldError.itemNotFound
    }
    guard case let .held(item) = entry.outcome else {
        if case let .failed(error) = entry.outcome { throw error }
        throw FileHoldError.itemNotFound
    }
    return item
}

func failure(
    of report: FileHoldIngestReport,
    at inputIndex: Int
) -> FileHoldError? {
    guard let entry = report.entries.first(where: { $0.inputIndex == inputIndex }),
          case let .failed(error) = entry.outcome else {
        return nil
    }
    return error
}

func relativeName(of item: HeldFileItem) -> String {
    guard case let .temporaryCopy(copy) = item.location else { return "" }
    return copy.relativeName
}

func waitForStage(in root: URL) async -> Bool {
    for _ in 0..<20_000 {
        if let names = try? directoryNames(root),
           names.contains(where: { $0.hasPrefix(".erylo-stage-") }) {
            return true
        }
        await Task.yield()
    }
    return false
}

func waitForPending(_ scheduler: ManualExpiryScheduler, count: Int) async -> Bool {
    for _ in 0..<2_000 {
        if await scheduler.pendingCount() == count { return true }
        await Task.yield()
    }
    return false
}

func waitForPending(_ scheduler: IgnoringCancellationExpiryScheduler, count: Int) async -> Bool {
    for _ in 0..<2_000 {
        if await scheduler.pendingCount() == count { return true }
        await Task.yield()
    }
    return false
}

@MainActor
func decodePreCancelledDropForTest(tracker: DragLoadTracker) async -> FileHoldDropReport {
    let provider = dragProvider(data: URL(fileURLWithPath: "/tmp/pre-cancel").dataRepresentation, tracker: tracker)
    return await Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return await PublicFileURLDropDecoder().decode([provider])
    }.value
}

@MainActor
func decodeThrowingTimeoutForTest(
    tracker: DragLoadTracker,
    controller: DeferredDragProviderController
) async -> FileHoldDropReport {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.fileURL.identifier,
        visibility: .all
    ) { completion in
        tracker.loaded()
        controller.install(completion)
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = { tracker.cancelled() }
        return progress
    }
    return await PublicFileURLDropDecoder(
        timeoutScheduler: ThrowingDropTimeoutScheduler(),
        loadObserver: controller
    ).decode([provider])
}

func waitForCancellation(_ scheduler: ManualExpiryScheduler, count: Int) async -> Bool {
    for _ in 0..<2_000 {
        if await scheduler.cancellationCount() == count { return true }
        await Task.yield()
    }
    return false
}

func waitForStatus(
    _ store: FileHoldStore,
    itemID: HeldFileID,
    expected: HeldFileStatus
) async -> Bool {
    for _ in 0..<2_000 {
        if await store.item(id: itemID)?.status == expected { return true }
        await Task.yield()
    }
    return false
}

func waitForDropTimeout(_ scheduler: ManualDropTimeoutScheduler) async -> Bool {
    for _ in 0..<2_000 {
        if await scheduler.waitCount() == 1 { return true }
        await Task.yield()
    }
    return false
}

func waitForDragCancellation(_ tracker: DragLoadTracker, count: Int) async -> Bool {
    for _ in 0..<2_000 {
        if tracker.cancellationCount == count { return true }
        await Task.yield()
    }
    return false
}

func waitForDeferredProvider(_ controller: DeferredDragProviderController) async -> Bool {
    for _ in 0..<2_000 {
        if controller.isInstalled && controller.isProgressInstalled { return true }
        await Task.yield()
    }
    return false
}

func yieldSeveralTimes() async {
    for _ in 0..<20 { await Task.yield() }
}
