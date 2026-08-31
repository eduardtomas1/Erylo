import EryloActivity
import EryloGlance
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
    private let controlPlane: (any ApplicationControlPlaneOwning)?
    private let focusTimer: FocusTimerRuntimeService?
    private let requestApplicationTermination: @MainActor () -> Void
    private let startupMeasurements: any ApplicationStartupMeasuring
    private var registeredServices: [any ApplicationRuntimeService] = []
    private var startedServices: [any ApplicationRuntimeService] = []
    private var admitsRegistrations = true
    private var startupTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var canCheckForUpdates = false
    private var isQuitRequested = false
    private var didRecordApplicationLaunch = false

    package init(
        activityBroker: ActivityBroker,
        activityModel: SurfaceActivityModel,
        panelCoordinator: PanelCoordinator,
        updateRuntime: UpdateRuntime,
        controlPlane: (any ApplicationControlPlaneOwning)? = nil,
        focusTimer: FocusTimerRuntimeService? = nil,
        startupMeasurements: any ApplicationStartupMeasuring = ApplicationStartupSignposter(),
        requestApplicationTermination: @escaping @MainActor () -> Void = {}
    ) {
        self.activityBroker = activityBroker
        self.activityModel = activityModel
        self.panelCoordinator = panelCoordinator
        self.updateRuntime = updateRuntime
        self.controlPlane = controlPlane
        self.focusTimer = focusTimer
        self.startupMeasurements = startupMeasurements
        self.requestApplicationTermination = requestApplicationTermination
        panelCoordinator.setPrimaryShortcutAdmissionHandler { [weak self] in
            self?.phase == .running
        }
        if let focusTimer {
            panelCoordinator.setFocusTimerStartHandler { [weak focusTimer] minutes in
                switch minutes {
                case FocusTimerPreset.fifteenMinutes.rawValue:
                    focusTimer?.requestStart(.fifteenMinutes) == true
                case FocusTimerPreset.twentyFiveMinutes.rawValue:
                    focusTimer?.requestStart(.twentyFiveMinutes) == true
                case FocusTimerPreset.fiftyMinutes.rawValue:
                    focusTimer?.requestStart(.fiftyMinutes) == true
                default:
                    false
                }
            }
        }
    }

    package func applicationDidFinishLaunching() {
        guard !didRecordApplicationLaunch else { return }
        didRecordApplicationLaunch = true
        startupMeasurements.record(.applicationDidFinishLaunching)
    }

    package static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestApplicationTermination: @escaping @MainActor () -> Void
    ) -> ApplicationRuntime {
        let activityBroker = ActivityBroker()
        let focusTimer = FocusTimerRuntimeService(broker: activityBroker)
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
            activityModel = SurfaceActivityModel(
                broker: activityBroker,
                actionHandler: FocusTimerActionRouter(
                    broker: activityBroker,
                    focusTimer: focusTimer
                )
            )
            panelCoordinator = PanelCoordinator(activityModel: activityModel)
        }
        #else
        _ = environment
        activityModel = SurfaceActivityModel(
            broker: activityBroker,
            actionHandler: FocusTimerActionRouter(
                broker: activityBroker,
                focusTimer: focusTimer
            )
        )
        panelCoordinator = PanelCoordinator(activityModel: activityModel)
        #endif

        panelCoordinator.setActivityVisibilityHandler { [weak focusTimer] isVisible in
            focusTimer?.setSurfaceVisible(isVisible)
        }
        let runtime = ApplicationRuntime(
            activityBroker: activityBroker,
            activityModel: activityModel,
            panelCoordinator: panelCoordinator,
            updateRuntime: UpdateRuntime(configuration: .mainBundle),
            controlPlane: ApplicationControlPlane.production(activityBroker: activityBroker),
            focusTimer: focusTimer,
            requestApplicationTermination: requestApplicationTermination
        )
        precondition(runtime.register(focusTimer), "Focus Timer service registration failed")
        return runtime
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
        restorationTask?.cancel()
        let task = Task { @MainActor [self] in
            _ = await startupTask?.value
            let restorationTask = restorationTask
            restorationTask?.cancel()
            _ = await restorationTask?.value
            self.restorationTask = nil
            await performShutdown()
            shutdownTask = nil
        }
        shutdownTask = task
        _ = await task.value
    }

    /// Routes deliberate menu commands through the one lifecycle owner.
    /// Commands fail closed before startup and after shutdown begins.
    @discardableResult
    package func handle(_ command: ApplicationControlCommand) -> Bool {
        if command == .quit {
            guard phase == .starting || phase == .running else { return false }
            guard !isQuitRequested else { return true }
            isQuitRequested = true
            requestApplicationTermination()
            return true
        }
        guard phase == .running else { return false }
        switch command {
        case .toggleSurface:
            return panelCoordinator.toggleSelectedPanelVisibility()
        case .startFocusTimer15:
            return focusTimer?.requestStart(.fifteenMinutes) == true
        case .startFocusTimer25:
            return focusTimer?.requestStart(.twentyFiveMinutes) == true
        case .startFocusTimer50:
            return focusTimer?.requestStart(.fiftyMinutes) == true
        case .cancelFocusTimer:
            return focusTimer?.requestCancel() == true
        case .showSettings:
            guard let controlPlane else { return false }
            return controlPlane.presentSettings()
        case .checkForUpdates:
            guard canCheckForUpdates else { return false }
            return updateRuntime.checkForUpdates()
        case .quit:
            return false
        }
    }

    private func performStartup() async {
        guard phase == .starting, !Task.isCancelled else { return }
        let initialDisplayPolicy = await controlPlane?.prepareForStartup()

        guard phase == .starting, !Task.isCancelled else { return }
        if let controlPlane,
           controlPlane.installEarlyControls(
               runtimeSnapshotProvider: { [weak self] in
                   self?.runtimeControlSnapshot() ?? .starting
               },
               commandHandler: { [weak self] command in
                   _ = self?.handle(command)
               },
               displayPolicyHandler: { [weak panelCoordinator] policy in
                   panelCoordinator?.update(policy: policy)
               }
           ) {
            startupMeasurements.record(.statusItemInstalled)
        }

        guard phase == .starting, !Task.isCancelled else { return }
        if let initialDisplayPolicy {
            panelCoordinator.update(policy: initialDisplayPolicy)
        }
        canCheckForUpdates = updateRuntime.startIfConfigured()

        guard phase == .starting, !Task.isCancelled else { return }
        await panelCoordinator.startAndWait()

        guard phase == .starting, !Task.isCancelled else { return }
        for service in registeredServices {
            await service.start()
            startedServices.append(service)
            guard phase == .starting, !Task.isCancelled else { return }
        }

        guard phase == .starting, !Task.isCancelled else { return }
        phase = .running
        beginPersistedModuleRestoration()
    }

    private func performShutdown() async {
        await controlPlane?.shutdown()
        for service in startedServices.reversed() {
            await service.shutdown()
        }
        startedServices.removeAll()
        registeredServices.removeAll()

        await panelCoordinator.shutdown()
        await activityBroker.shutdown()
        updateRuntime.shutdown()
        canCheckForUpdates = false
        phase = .stopped
    }

    private func runtimeControlSnapshot() -> ApplicationRuntimeControlSnapshot {
        let coreCommandsAreAdmitted = phase == .running
        let focusCommandsAreAdmitted = coreCommandsAreAdmitted && focusTimer != nil
        return ApplicationRuntimeControlSnapshot(
            coreCommandsAreAdmitted: coreCommandsAreAdmitted,
            focusCommandsAreAdmitted: focusCommandsAreAdmitted,
            quitCommandIsAdmitted: phase == .starting || phase == .running,
            canCheckForUpdates: coreCommandsAreAdmitted && canCheckForUpdates,
            focusTimer: focusCommandsAreAdmitted
                ? (focusTimer?.menuContext(at: Date()) ?? .idle)
                : .idle,
            surface: panelCoordinator.selectedSurfaceState
        )
    }

    private func beginPersistedModuleRestoration() {
        guard restorationTask == nil, let controlPlane else { return }
        startupMeasurements.record(.restorationStarted)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let didSettle = await controlPlane.restorePersistedModules()
            guard !Task.isCancelled, self.phase == .running else { return }
            if didSettle {
                self.startupMeasurements.record(.restorationCompleted)
            }
            self.restorationTask = nil
        }
        restorationTask = task
    }
}
