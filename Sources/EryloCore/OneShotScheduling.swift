@MainActor
public protocol ScheduledOperation: AnyObject {
    func cancel()
}

@MainActor
public protocol OneShotScheduling: AnyObject {
    @discardableResult
    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any ScheduledOperation
}

@MainActor
public final class TaskOneShotScheduler: OneShotScheduling {
    public init() {}

    public func schedule(
        after delay: Duration,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any ScheduledOperation {
        let scheduledOperation = TaskScheduledOperation()
        scheduledOperation.task = Task { @MainActor [weak scheduledOperation] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard scheduledOperation?.isCancelled == false else { return }
            operation()
        }
        return scheduledOperation
    }
}

@MainActor
private final class TaskScheduledOperation: ScheduledOperation {
    var task: Task<Void, Never>?
    private(set) var isCancelled = false

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
