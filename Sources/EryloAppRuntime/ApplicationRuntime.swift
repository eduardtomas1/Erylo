import EryloActivity
import EryloSurface
import EryloUpdates
import EryloWindowing
import Foundation

/// A process service registered by the composition root. Construction must be inert.
/// `start()` should cooperate with cancellation; `shutdown()` must return only after
/// the service has released all tasks, observers, timers, network work, and permissions.
@MainActor
package protocol ApplicationRuntimeService: AnyObject {
    func start() async
    func shutdown() async
}

package enum ApplicationRuntimePhase: Equatable, Sendable {
    case initialized
    case starting
    case running
    case shuttingDown
    case stopped
}

/// The single app-level owner for process resources and their terminal lifecycle.
@MainActor
package final class ApplicationRuntime {
    package let activityBroker: ActivityBroker
    package private(set) var phase: ApplicationRuntimePhase = .initialized

    private let activityModel: SurfaceActivityModel
    private let panelCoordinator: PanelCoordinator
    private let updateRuntime: UpdateRuntime
    private var registeredServices: [any ApplicationRuntimeService] = []
    private var startedServices: [any ApplicationRuntimeService] = []
    private var admitsRegistrations = true
    private var startupTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    package init(
        activityBroker: ActivityBroker,
        activityModel: SurfaceActivityModel,
        panelCoordinator: PanelCoordinator,
        updateRuntime: UpdateRuntime
    ) {
        self.activityBroker = activityBroker
        self.activityModel = activityModel
        self.panelCoordinator = panelCoordinator
        self.updateRuntime = updateRuntime
    }

    package static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ApplicationRuntime {
        let activityBroker = ActivityBroker()
        let activityModel: SurfaceActivityModel
        let panelCoordinator: PanelCoordinator

        #if DEBUG
        if environment["ERYLO_PREVIEW_SCENARIO"] == "timer",
           let snapshot = try? ActivitySurfacePreviewCatalog.timer.snapshot() {
            activityModel = SurfaceActivityModel(previewSnapshot: snapshot)
            panelCoordinator = PanelCoordinator(
                activityModel: activityModel,
                previewInitialState: ActivitySurfacePreviewCatalog.timer.state
            )
        } else {
            activityModel = SurfaceActivityModel(broker: activityBroker)
            panelCoordinator = PanelCoordinator(activityModel: activityModel)
        }
        #else
        _ = environment
        activityModel = SurfaceActivityModel(broker: activityBroker)
        panelCoordinator = PanelCoordinator(activityModel: activityModel)
        #endif

        return ApplicationRuntime(
            activityBroker: activityBroker,
            activityModel: activityModel,
            panelCoordinator: panelCoordinator,
            updateRuntime: UpdateRuntime(configuration: .mainBundle)
        )
    }

    /// Registration is deliberately limited to composition time so startup order is stable.
    @discardableResult
    package func register(_ service: any ApplicationRuntimeService) -> Bool {
        guard admitsRegistrations, phase == .initialized else { return false }
        let identity = ObjectIdentifier(service)
        guard !registeredServices.contains(where: { ObjectIdentifier($0) == identity }) else {
            return false
        }
        registeredServices.append(service)
        return true
    }

    /// Starts the updater, surface, and registered services in that fixed order.
    /// The owned task makes the physical transition insensitive to caller cancellation.
    @discardableResult
    package func start() async -> Bool {
        guard phase != .shuttingDown, phase != .stopped else { return false }
        if let startupTask {
            _ = await startupTask.value
            return phase == .running
        }
        guard phase == .initialized else { return phase == .running }

        admitsRegistrations = false
        phase = .starting
        let task = Task { @MainActor [self] in
            await performStartup()
            startupTask = nil
        }
        startupTask = task
        _ = await task.value
        return phase == .running
    }

    /// Irreversibly closes lifecycle admission, joins any overlapping startup,
    /// and performs a cancellation-insensitive, reverse-dependency drain once.
    package func shutdown() async {
        if let shutdownTask {
            _ = await shutdownTask.value
            return
        }
        guard phase != .stopped else { return }

        admitsRegistrations = false
        phase = .shuttingDown
        let startupTask = startupTask
        startupTask?.cancel()
        let task = Task { @MainActor [self] in
            _ = await startupTask?.value
            await performShutdown()
            shutdownTask = nil
        }
        shutdownTask = task
        _ = await task.value
    }

    private func performStartup() async {
        guard phase == .starting, !Task.isCancelled else { return }
        _ = updateRuntime.startIfConfigured()

        guard phase == .starting, !Task.isCancelled else { return }
        await panelCoordinator.startAndWait()

        guard phase == .starting, !Task.isCancelled else { return }
        for service in registeredServices {
            await service.start()
            startedServices.append(service)
            guard phase == .starting, !Task.isCancelled else { return }
        }
        phase = .running
    }

    private func performShutdown() async {
        for service in startedServices.reversed() {
            await service.shutdown()
        }
        startedServices.removeAll()
        registeredServices.removeAll()

        await panelCoordinator.shutdown()
        await activityBroker.shutdown()
        updateRuntime.shutdown()
        phase = .stopped
    }
}
