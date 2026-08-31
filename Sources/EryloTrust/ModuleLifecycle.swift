import Foundation

public protocol ModuleLifecycleProvider: Sendable {
    /// Starts event-driven work. Implementations must not request permission from this method.
    func start() async throws
    /// Returns only after permission-dependent, CPU, timer, and network work has stopped.
    func stop() async
}

public protocol ModuleProviderFactory: Sendable {
    /// Construction must be side-effect free. Work begins only when `start()` is called.
    func makeProvider(for module: EryloModule) async throws -> any ModuleLifecycleProvider
}

public protocol ModulePermissionRequesting: Sendable {
    func requestPermission(
        _ requirement: ModulePermissionRequirement,
        for module: EryloModule
    ) async throws
}

public enum PermissionRequestPolicy: Equatable, Sendable {
    case doNotRequest
    /// Valid only after a contextual user action that explains why access is useful.
    case requestIfNeeded
}

public enum TrustLifecycleLimits {
    public static let maximumQueuedOperations = 8
}

public enum TrustSettingsChange: Sendable {
    case displays(DisplayPreferences)
    case motion(MotionPreference)
    case fullscreen(FullscreenBehavior)
    case crashAndDiagnosticSharingConsent(Bool)
    case onboardingCompleted(Bool)
}

public enum TrustUpdateOutcome: String, Equatable, Sendable {
    case noChange = "no-change"
    case applied
    case rolledBack = "rolled-back"
    case failed
}

public enum TrustUpdateFailure: String, Error, Equatable, Sendable {
    case permissionDenied = "permission-denied"
    case providerFactoryFailed = "provider-factory-failed"
    case providerStartFailed = "provider-start-failed"
    case persistenceFailed = "persistence-failed"
    case rollbackFailed = "rollback-failed"
    case launchAtLoginFailed = "launch-at-login-failed"
    case operationCancelled = "operation-cancelled"
    case operationSuperseded = "operation-superseded"
    case queueCapacityExceeded = "queue-capacity-exceeded"
    case coordinatorShutDown = "coordinator-shut-down"
}

public struct TrustSettingsUpdateResult: Equatable, Sendable {
    public let settings: EryloSettings
    public let outcome: TrustUpdateOutcome
    public let failure: TrustUpdateFailure?
    public let launchAtLogin: LaunchAtLoginSnapshot?

    public init(
        settings: EryloSettings,
        outcome: TrustUpdateOutcome,
        failure: TrustUpdateFailure? = nil,
        launchAtLogin: LaunchAtLoginSnapshot? = nil
    ) {
        self.settings = settings
        self.outcome = outcome
        self.failure = failure
        self.launchAtLogin = launchAtLogin
    }
}

/// One result for each module that was enabled in the persisted launch snapshot.
/// Keeping the module identity beside the update result lets the application
/// present bounded recovery copy without exposing provider or persistence errors.
package struct PersistedModuleRestoreResult: Equatable, Sendable {
    package let module: EryloModule
    package let update: TrustSettingsUpdateResult

    package init(module: EryloModule, update: TrustSettingsUpdateResult) {
        self.module = module
        self.update = update
    }

    package var settings: EryloSettings { update.settings }
    package var outcome: TrustUpdateOutcome { update.outcome }
    package var failure: TrustUpdateFailure? { update.failure }
}

public struct DiagnosticsContext: Sendable {
    public let settings: EryloSettings
    public let providerHealth: [ProviderHealthSnapshot]

    public init(settings: EryloSettings, providerHealth: [ProviderHealthSnapshot]) {
        self.settings = settings
        self.providerHealth = providerHealth
    }
}

public struct StopAllResult: Equatable, Sendable {
    public let stoppedModules: [EryloModule]

    public init(stoppedModules: [EryloModule]) {
        self.stoppedModules = stoppedModules
    }
}

public protocol TrustSettingsCoordinating: Sendable {
    func currentSettings() async -> EryloSettings
    func launchAtLoginSnapshot() async -> LaunchAtLoginSnapshot
    func setModuleEnabled(
        _ module: EryloModule,
        enabled: Bool,
        permissionPolicy: PermissionRequestPolicy
    ) async -> TrustSettingsUpdateResult
    func apply(_ change: TrustSettingsChange) async -> TrustSettingsUpdateResult
    func setLaunchAtLoginEnabled(_ enabled: Bool) async -> TrustSettingsUpdateResult
    func resetToSafeDefaults() async -> TrustSettingsUpdateResult
    func diagnosticsContext() async -> DiagnosticsContext
}

public actor TrustSettingsCoordinator: TrustSettingsCoordinating {
    private let repository: SettingsRepository
    private let providerFactory: any ModuleProviderFactory
    private let permissionRequester: any ModulePermissionRequesting
    private let launchAtLoginController: any LaunchAtLoginControlling
    private let events: any DiagnosticEventRecording
    private let gate = SerialOperationGate()
    private var activeProviders: [EryloModule: any ModuleLifecycleProvider] = [:]
    private var providerHealthByModule: [EryloModule: ProviderHealthSnapshot] = [:]
    private var shutdownHasBegun = false
    private var shutdownTask: Task<StopAllResult, Never>?
    private var shutdownResult: StopAllResult?

    public init(
        repository: SettingsRepository,
        providerFactory: any ModuleProviderFactory,
        permissionRequester: any ModulePermissionRequesting,
        launchAtLoginController: any LaunchAtLoginControlling,
        events: any DiagnosticEventRecording
    ) {
        self.repository = repository
        self.providerFactory = providerFactory
        self.permissionRequester = permissionRequester
        self.launchAtLoginController = launchAtLoginController
        self.events = events
    }

    public func currentSettings() async -> EryloSettings {
        await repository.current()
    }

    public func loadReport() async -> SettingsLoadReport {
        await repository.loadReport()
    }

    public func launchAtLoginSnapshot() async -> LaunchAtLoginSnapshot {
        await launchAtLoginController.snapshot()
    }

    public func activeModules() -> Set<EryloModule> {
        Set(activeProviders.keys)
    }

    public func providerHealth() -> [ProviderHealthSnapshot] {
        EryloModule.allCases.map { module in
            providerHealthByModule[module]
                ?? ProviderHealthSnapshot(module: module, state: .disabled)
        }
    }

    public func diagnosticsContext() async -> DiagnosticsContext {
        DiagnosticsContext(
            settings: await repository.current(),
            providerHealth: providerHealth()
        )
    }

    /// Reads persisted intent and starts only modules already enabled. It never requests access.
    public func startEnabledModules() async -> [TrustSettingsUpdateResult] {
        guard !shutdownHasBegun else { return [await shutDownResult()] }
        do {
            try await gate.acquire(key: .startup)
        } catch let error {
            return [await gateFailureResult(error)]
        }
        if shutdownHasBegun {
            await gate.release()
            return [await shutDownResult()]
        }
        if Task.isCancelled {
            await gate.release()
            return [await cancelledResult()]
        }
        let settings = await repository.current()
        var results: [TrustSettingsUpdateResult] = []
        for module in settings.modules.enabledModules.sorted(by: { $0.rawValue < $1.rawValue }) {
            results.append(
                await performSetModuleEnabled(
                    module,
                    enabled: true,
                    permissionPolicy: .doNotRequest
                )
            )
        }
        await gate.release()
        return results
    }

    /// Identity-preserving launch restoration for application owners that need
    /// to aggregate one bounded recovery outcome per persisted module.
    package func restoreEnabledModules() async -> [PersistedModuleRestoreResult] {
        let launchSettings = await repository.current()
        let modules = launchSettings.modules.enabledModules.sorted { $0.rawValue < $1.rawValue }
        guard !modules.isEmpty else { return [] }
        guard !shutdownHasBegun else {
            let result = await shutDownResult()
            return modules.map { PersistedModuleRestoreResult(module: $0, update: result) }
        }
        do {
            try await gate.acquire(key: .startup)
        } catch let error {
            let result = await gateFailureResult(error)
            return modules.map { PersistedModuleRestoreResult(module: $0, update: result) }
        }
        if shutdownHasBegun {
            await gate.release()
            let result = await shutDownResult()
            return modules.map { PersistedModuleRestoreResult(module: $0, update: result) }
        }
        if Task.isCancelled {
            await gate.release()
            let result = await cancelledResult()
            return modules.map { PersistedModuleRestoreResult(module: $0, update: result) }
        }
        var results: [PersistedModuleRestoreResult] = []
        for module in modules {
            let update = await performSetModuleEnabled(
                    module,
                    enabled: true,
                    permissionPolicy: .doNotRequest
                )
            results.append(PersistedModuleRestoreResult(module: module, update: update))
        }
        await gate.release()
        return results
    }

    public func setModuleEnabled(
        _ module: EryloModule,
        enabled: Bool,
        permissionPolicy: PermissionRequestPolicy = .doNotRequest
    ) async -> TrustSettingsUpdateResult {
        guard !shutdownHasBegun else { return await shutDownResult() }
        do {
            try await gate.acquire(key: .module(module))
        } catch let error {
            return await gateFailureResult(error)
        }
        if shutdownHasBegun {
            await gate.release()
            return await shutDownResult()
        }
        if Task.isCancelled {
            await gate.release()
            return await cancelledResult()
        }
        let result = await performSetModuleEnabled(
            module,
            enabled: enabled,
            permissionPolicy: permissionPolicy
        )
        await gate.release()
        return result
    }

    public func apply(_ change: TrustSettingsChange) async -> TrustSettingsUpdateResult {
        guard !shutdownHasBegun else { return await shutDownResult() }
        do {
            try await gate.acquire(key: change.gateKey)
        } catch let error {
            return await gateFailureResult(error)
        }
        if shutdownHasBegun {
            await gate.release()
            return await shutDownResult()
        }
        let previous = await repository.current()
        if Task.isCancelled {
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .failed,
                failure: .operationCancelled
            )
        }
        let candidate: EryloSettings
        do {
            candidate = try await repository.update { settings in
                switch change {
                case let .displays(displays):
                    settings.displays = displays
                case let .motion(motion):
                    settings.motion = motion
                case let .fullscreen(fullscreen):
                    settings.fullscreenBehavior = fullscreen
                case let .crashAndDiagnosticSharingConsent(consent):
                    settings.crashAndDiagnosticSharingConsent = consent
                case let .onboardingCompleted(completed):
                    settings.onboardingCompleted = completed
                }
            }
        } catch {
            await events.record(
                severity: .error,
                subsystem: .settings,
                code: .settingsPersistFailed,
                module: nil
            )
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .failed,
                failure: .persistenceFailed
            )
        }
        await gate.release()
        return TrustSettingsUpdateResult(settings: candidate, outcome: .applied)
    }

    public func setLaunchAtLoginEnabled(_ enabled: Bool) async -> TrustSettingsUpdateResult {
        guard !shutdownHasBegun else { return await shutDownResult() }
        do {
            try await gate.acquire(key: .launchAtLogin)
        } catch let error {
            return await gateFailureResult(error)
        }
        if shutdownHasBegun {
            await gate.release()
            return await shutDownResult()
        }
        let previous = await repository.current()
        if Task.isCancelled {
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .failed,
                failure: .operationCancelled
            )
        }
        let initialSnapshot = await launchAtLoginController.snapshot()
        if previous.launchAtLogin == enabled,
           Self.launchChangeSucceeded(enabled: enabled, snapshot: initialSnapshot) {
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .noChange,
                launchAtLogin: initialSnapshot
            )
        }

        let updatedSnapshot = await launchAtLoginController.setEnabled(enabled)
        if Task.isCancelled {
            let rollback = await launchAtLoginController.setEnabled(previous.launchAtLogin)
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .rolledBack,
                failure: .operationCancelled,
                launchAtLogin: rollback
            )
        }
        guard Self.launchChangeSucceeded(enabled: enabled, snapshot: updatedSnapshot) else {
            await events.record(
                severity: .error,
                subsystem: .launchAtLogin,
                code: .launchAtLoginFailed,
                module: nil
            )
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .failed,
                failure: .launchAtLoginFailed,
                launchAtLogin: updatedSnapshot
            )
        }

        do {
            let settings = try await repository.update { $0.launchAtLogin = enabled }
            await events.record(
                severity: .info,
                subsystem: .launchAtLogin,
                code: .launchAtLoginChanged,
                module: nil
            )
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: settings,
                outcome: .applied,
                launchAtLogin: updatedSnapshot
            )
        } catch {
            let rollback = await launchAtLoginController.setEnabled(previous.launchAtLogin)
            let rollbackSucceeded = Self.launchChangeSucceeded(
                enabled: previous.launchAtLogin,
                snapshot: rollback
            )
            await events.record(
                severity: .error,
                subsystem: .settings,
                code: .settingsPersistFailed,
                module: nil
            )
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: rollbackSucceeded ? .rolledBack : .failed,
                failure: rollbackSucceeded ? .persistenceFailed : .rollbackFailed,
                launchAtLogin: rollback
            )
        }
    }

    public func resetToSafeDefaults() async -> TrustSettingsUpdateResult {
        guard !shutdownHasBegun else { return await shutDownResult() }
        do {
            try await gate.acquire(key: .reset)
        } catch let error {
            return await gateFailureResult(error)
        }
        if shutdownHasBegun {
            await gate.release()
            return await shutDownResult()
        }
        let previous = await repository.current()
        if Task.isCancelled {
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .failed,
                failure: .operationCancelled
            )
        }
        let previouslyActive = activeProviders

        for (module, provider) in previouslyActive {
            await provider.stop()
            activeProviders.removeValue(forKey: module)
            providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .disabled)
        }

        if Task.isCancelled {
            let restored = await restart(providers: previouslyActive)
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: restored ? .rolledBack : .failed,
                failure: restored ? .operationCancelled : .rollbackFailed
            )
        }

        let initialLaunchSnapshot = await launchAtLoginController.snapshot()
        let launchNeedsDisable = previous.launchAtLogin
            || initialLaunchSnapshot.registrationState == .enabled
            || initialLaunchSnapshot.registrationState == .requiresApproval
        let launchSnapshot = launchNeedsDisable
            ? await launchAtLoginController.setEnabled(false)
            : initialLaunchSnapshot
        if Task.isCancelled {
            let launchRollback = launchNeedsDisable
                ? await launchAtLoginController.setEnabled(previous.launchAtLogin)
                : initialLaunchSnapshot
            let providersRestored = await restart(providers: previouslyActive)
            let launchRestored = !launchNeedsDisable || Self.launchChangeSucceeded(
                    enabled: previous.launchAtLogin,
                    snapshot: launchRollback
                )
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: providersRestored && launchRestored ? .rolledBack : .failed,
                failure: providersRestored && launchRestored ? .operationCancelled : .rollbackFailed,
                launchAtLogin: launchRollback
            )
        }
        guard !launchNeedsDisable
                || Self.launchChangeSucceeded(enabled: false, snapshot: launchSnapshot) else {
            let launchRollback = await launchAtLoginController.setEnabled(previous.launchAtLogin)
            let providersRestored = await restart(providers: previouslyActive)
            let launchRestored = Self.launchChangeSucceeded(
                enabled: previous.launchAtLogin,
                snapshot: launchRollback
            )
            await events.record(
                severity: .error,
                subsystem: .launchAtLogin,
                code: .launchAtLoginFailed,
                module: nil
            )
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: providersRestored && launchRestored ? .rolledBack : .failed,
                failure: providersRestored && launchRestored ? .launchAtLoginFailed : .rollbackFailed,
                launchAtLogin: launchRollback
            )
        }

        do {
            let settings = try await repository.resetToSafeDefaults()
            await events.record(
                severity: .info,
                subsystem: .settings,
                code: .settingsReset,
                module: nil
            )
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: settings,
                outcome: .applied,
                launchAtLogin: launchSnapshot
            )
        } catch {
            let launchRollback = launchNeedsDisable
                ? await launchAtLoginController.setEnabled(previous.launchAtLogin)
                : initialLaunchSnapshot
            let providersRestored = await restart(providers: previouslyActive)
            let launchRestored = !launchNeedsDisable || Self.launchChangeSucceeded(
                    enabled: previous.launchAtLogin,
                    snapshot: launchRollback
                )
            await events.record(
                severity: .error,
                subsystem: .settings,
                code: .settingsPersistFailed,
                module: nil
            )
            await gate.release()
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: providersRestored && launchRestored ? .rolledBack : .failed,
                failure: providersRestored && launchRestored ? .persistenceFailed : .rollbackFailed,
                launchAtLogin: launchRollback
            )
        }
    }

    /// Explicit terminal shutdown boundary. Once called, new and pending mutations are rejected.
    /// The shutdown work ignores caller cancellation, and return means every retained provider
    /// has completed `stop()` and no later operation can restart work.
    public func stopAll() async -> StopAllResult {
        if let shutdownResult { return shutdownResult }
        if let shutdownTask { return await shutdownTask.value }

        shutdownHasBegun = true
        let task = Task.detached { [self] in
            await performTerminalShutdown()
        }
        shutdownTask = task
        let result = await task.value
        shutdownResult = result
        shutdownTask = nil
        return result
    }

    private func performTerminalShutdown() async -> StopAllResult {
        await gate.beginShutdown()
        let modules = activeProviders.keys.sorted { $0.rawValue < $1.rawValue }
        for module in modules {
            if let provider = activeProviders.removeValue(forKey: module) {
                await provider.stop()
            }
            providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .disabled)
        }
        await gate.release()
        return StopAllResult(stoppedModules: modules)
    }

    private func performSetModuleEnabled(
        _ module: EryloModule,
        enabled: Bool,
        permissionPolicy: PermissionRequestPolicy
    ) async -> TrustSettingsUpdateResult {
        if enabled {
            return await enable(module, permissionPolicy: permissionPolicy)
        }
        return await disable(module)
    }

    private func enable(
        _ module: EryloModule,
        permissionPolicy: PermissionRequestPolicy
    ) async -> TrustSettingsUpdateResult {
        let previous = await repository.current()
        if Task.isCancelled {
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .failed,
                failure: .operationCancelled
            )
        }
        if previous.modules[module], activeProviders[module] != nil {
            return TrustSettingsUpdateResult(settings: previous, outcome: .noChange)
        }

        providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .starting)

        if let permissionRequirement = module.permissionRequirement,
           permissionPolicy == .requestIfNeeded {
            do {
                try await permissionRequester.requestPermission(
                    permissionRequirement,
                    for: module
                )
            } catch {
                return await failedEnable(
                    module,
                    previous: previous,
                    failure: .permissionDenied,
                    providerFailure: .permissionDenied
                )
            }
            if Task.isCancelled {
                return cancelledEnable(module, previous: previous)
            }
        }

        let provider: any ModuleLifecycleProvider
        do {
            provider = try await providerFactory.makeProvider(for: module)
        } catch {
            return await failedEnable(
                module,
                previous: previous,
                failure: .providerFactoryFailed,
                providerFailure: .factoryFailed
            )
        }
        if Task.isCancelled {
            return cancelledEnable(module, previous: previous)
        }

        do {
            try await provider.start()
        } catch {
            await provider.stop()
            return await failedEnable(
                module,
                previous: previous,
                failure: .providerStartFailed,
                providerFailure: .startFailed
            )
        }
        if Task.isCancelled {
            await provider.stop()
            return cancelledEnable(module, previous: previous)
        }

        do {
            let settings: EryloSettings
            if previous.modules[module] {
                settings = previous
            } else {
                settings = try await repository.update { $0.modules[module] = true }
            }
            activeProviders[module] = provider
            providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .running)
            await events.record(
                severity: .info,
                subsystem: .lifecycle,
                code: .moduleEnabled,
                module: module
            )
            return TrustSettingsUpdateResult(settings: settings, outcome: .applied)
        } catch {
            await provider.stop()
            providerHealthByModule[module] = ProviderHealthSnapshot(
                module: module,
                state: .failed,
                failure: .persistenceFailed
            )
            await events.record(
                severity: .error,
                subsystem: .settings,
                code: .settingsPersistFailed,
                module: module
            )
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .rolledBack,
                failure: .persistenceFailed
            )
        }
    }

    private func disable(_ module: EryloModule) async -> TrustSettingsUpdateResult {
        let previous = await repository.current()
        if Task.isCancelled {
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: .failed,
                failure: .operationCancelled
            )
        }
        let provider = activeProviders.removeValue(forKey: module)
        if let provider {
            await provider.stop()
        }

        if Task.isCancelled {
            var restored = true
            if let provider {
                do {
                    try await provider.start()
                    activeProviders[module] = provider
                    providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .running)
                } catch {
                    restored = false
                    providerHealthByModule[module] = ProviderHealthSnapshot(
                        module: module,
                        state: .failed,
                        failure: .rollbackFailed
                    )
                }
            }
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: restored ? .rolledBack : .failed,
                failure: restored ? .operationCancelled : .rollbackFailed
            )
        }

        guard previous.modules[module] else {
            providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .disabled)
            return TrustSettingsUpdateResult(settings: previous, outcome: provider == nil ? .noChange : .applied)
        }

        do {
            let settings = try await repository.update { $0.modules[module] = false }
            providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .disabled)
            await events.record(
                severity: .info,
                subsystem: .lifecycle,
                code: .moduleDisabled,
                module: module
            )
            return TrustSettingsUpdateResult(settings: settings, outcome: .applied)
        } catch {
            var rollbackSucceeded = true
            if let provider {
                do {
                    try await provider.start()
                    activeProviders[module] = provider
                    providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .running)
                } catch {
                    rollbackSucceeded = false
                    providerHealthByModule[module] = ProviderHealthSnapshot(
                        module: module,
                        state: .failed,
                        failure: .rollbackFailed
                    )
                    await events.record(
                        severity: .error,
                        subsystem: .lifecycle,
                        code: .moduleRollbackFailed,
                        module: module
                    )
                }
            }
            await events.record(
                severity: .error,
                subsystem: .lifecycle,
                code: .moduleDisableFailed,
                module: module
            )
            return TrustSettingsUpdateResult(
                settings: previous,
                outcome: rollbackSucceeded ? .rolledBack : .failed,
                failure: rollbackSucceeded ? .persistenceFailed : .rollbackFailed
            )
        }
    }

    private func failedEnable(
        _ module: EryloModule,
        previous: EryloSettings,
        failure: TrustUpdateFailure,
        providerFailure: ProviderFailureCode
    ) async -> TrustSettingsUpdateResult {
        var finalSettings = previous
        var finalFailure = failure
        if previous.modules[module] {
            do {
                finalSettings = try await repository.update { $0.modules[module] = false }
            } catch {
                finalFailure = .persistenceFailed
            }
        }
        providerHealthByModule[module] = ProviderHealthSnapshot(
            module: module,
            state: .failed,
            failure: providerFailure
        )
        await events.record(
            severity: .error,
            subsystem: .lifecycle,
            code: .moduleEnableFailed,
            module: module
        )
        return TrustSettingsUpdateResult(
            settings: finalSettings,
            outcome: .failed,
            failure: finalFailure
        )
    }

    private func cancelledEnable(
        _ module: EryloModule,
        previous: EryloSettings
    ) -> TrustSettingsUpdateResult {
        providerHealthByModule[module] = ProviderHealthSnapshot(
            module: module,
            state: .failed,
            failure: .operationCancelled
        )
        return TrustSettingsUpdateResult(
            settings: previous,
            outcome: .failed,
            failure: .operationCancelled
        )
    }

    private func restart(
        providers: [EryloModule: any ModuleLifecycleProvider]
    ) async -> Bool {
        var allRestarted = true
        for (module, provider) in providers {
            do {
                try await provider.start()
                activeProviders[module] = provider
                providerHealthByModule[module] = ProviderHealthSnapshot(module: module, state: .running)
            } catch {
                allRestarted = false
                providerHealthByModule[module] = ProviderHealthSnapshot(
                    module: module,
                    state: .failed,
                    failure: .rollbackFailed
                )
            }
        }
        return allRestarted
    }

    private static func launchChangeSucceeded(
        enabled: Bool,
        snapshot: LaunchAtLoginSnapshot
    ) -> Bool {
        guard snapshot.failure == nil, snapshot.capability == .available else { return false }
        if enabled {
            return snapshot.registrationState == .enabled
                || snapshot.registrationState == .requiresApproval
        }
        return snapshot.registrationState == .disabled
    }

    private func gateFailureResult(_ error: SerialGateError) async -> TrustSettingsUpdateResult {
        let failure: TrustUpdateFailure = switch error {
        case .cancelled: .operationCancelled
        case .superseded: .operationSuperseded
        case .capacityExceeded: .queueCapacityExceeded
        case .shuttingDown: .coordinatorShutDown
        }
        return TrustSettingsUpdateResult(
            settings: await repository.current(),
            outcome: .failed,
            failure: failure
        )
    }

    private func cancelledResult() async -> TrustSettingsUpdateResult {
        TrustSettingsUpdateResult(
            settings: await repository.current(),
            outcome: .failed,
            failure: .operationCancelled
        )
    }

    private func shutDownResult() async -> TrustSettingsUpdateResult {
        TrustSettingsUpdateResult(
            settings: await repository.current(),
            outcome: .failed,
            failure: .coordinatorShutDown
        )
    }
}

private enum SerialOperationKey: Hashable, Sendable {
    case module(EryloModule)
    case displays
    case motion
    case fullscreen
    case diagnosticsConsent
    case onboarding
    case launchAtLogin
    case reset
    case startup
}

private extension TrustSettingsChange {
    var gateKey: SerialOperationKey {
        switch self {
        case .displays: .displays
        case .motion: .motion
        case .fullscreen: .fullscreen
        case .crashAndDiagnosticSharingConsent: .diagnosticsConsent
        case .onboardingCompleted: .onboarding
        }
    }
}

private enum SerialGateError: Error, Equatable, Sendable {
    case cancelled
    case superseded
    case capacityExceeded
    case shuttingDown
}

private actor SerialOperationGate {
    private struct Waiter {
        let identifier: UUID
        let key: SerialOperationKey
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isLocked = false
    private var isShutDown = false
    private var waiters: [Waiter] = []
    private var shutdownContinuation: CheckedContinuation<Void, Never>?

    func acquire(key: SerialOperationKey) async throws(SerialGateError) {
        guard !isShutDown else { throw .shuttingDown }
        guard !Task.isCancelled else { throw .cancelled }
        if !isLocked {
            isLocked = true
            return
        }

        let identifier = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    guard !isShutDown else {
                        continuation.resume(throwing: SerialGateError.shuttingDown)
                        return
                    }
                    if let existingIndex = waiters.firstIndex(where: { $0.key == key }) {
                        let existing = waiters.remove(at: existingIndex)
                        existing.continuation.resume(throwing: SerialGateError.superseded)
                    }

                    guard waiters.count < TrustLifecycleLimits.maximumQueuedOperations else {
                        continuation.resume(throwing: SerialGateError.capacityExceeded)
                        return
                    }

                    let waiter = Waiter(
                        identifier: identifier,
                        key: key,
                        continuation: continuation
                    )
                    waiters.append(waiter)
                }
            } onCancel: {
                Task { await self.cancel(identifier) }
            }
        } catch let error as SerialGateError {
            throw error
        } catch {
            throw .cancelled
        }
        if Task.isCancelled {
            release()
            throw .cancelled
        }
    }

    /// Permanently closes the gate, rejects all queued/future work, and waits for the current
    /// owner without observing cancellation from the caller that initiated application shutdown.
    func beginShutdown() async {
        guard !isShutDown else { return }
        isShutDown = true

        let displaced = waiters
        waiters.removeAll(keepingCapacity: false)
        displaced.forEach {
            $0.continuation.resume(throwing: SerialGateError.shuttingDown)
        }

        guard isLocked else {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            shutdownContinuation = continuation
        }
    }

    func release() {
        if let shutdownContinuation {
            self.shutdownContinuation = nil
            shutdownContinuation.resume()
            return
        }
        if isShutDown {
            isLocked = false
            return
        }
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(_ identifier: UUID) {
        guard let index = waiters.firstIndex(where: { $0.identifier == identifier }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: SerialGateError.cancelled)
    }
}
